//! sasq: experimental fused SAS -> Parquet converter.
//!
//! Pipeline: one reader thread decodes columnar batches into Arrow arrays;
//! N encoder threads compress row groups in parallel; a writer thread appends
//! encoded row groups to the file in original order.

use std::collections::BTreeMap;
use std::fs::File;
use std::path::PathBuf;
use std::sync::Arc;
use std::thread;
use std::time::Instant;

use arrow_array::builder::StringBuilder;
use arrow_array::{
    ArrayRef, Date32Array, Float64Array, RecordBatch, Time64MicrosecondArray,
    TimestampMicrosecondArray,
};
use arrow_buffer::NullBufferBuilder;
use arrow_schema::{DataType, Field, Schema, SchemaRef, TimeUnit};
use arrow_select::concat::concat;
use crossbeam_channel::bounded;
use parquet::arrow::arrow_writer::{compute_leaves, get_column_writers, ArrowColumnChunk};
use parquet::arrow::ArrowSchemaConverter;
use parquet::basic::{Compression, ZstdLevel};
use parquet::file::properties::{EnabledStatistics, WriterProperties};
use parquet::file::writer::SerializedFileWriter;
use parquet::schema::types::SchemaDescriptor;
use sas7bdat::parser::{ColumnKind, NumericKind};
use sas7bdat::SasReader;

const SAS_EPOCH_DAYS: i32 = 3653; // 1960-01-01 -> 1970-01-01
const SAS_EPOCH_SECS: i64 = 315_619_200;

type AnyError = Box<dyn std::error::Error + Send + Sync>;

fn main() -> Result<(), AnyError> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: sasq <in.sas7bdat> <out.parquet> [rg_rows] [zstd_level]");
        std::process::exit(2);
    }
    let src = PathBuf::from(&args[1]);
    let dst = PathBuf::from(&args[2]);
    let rg_rows: usize = args.get(3).map(|s| s.parse()).transpose()?.unwrap_or(262_144);
    let zstd_level: i32 = args.get(4).map(|s| s.parse()).transpose()?.unwrap_or(1);

    let t0 = Instant::now();

    let sas = SasReader::open(&src)?;
    let (mut file, layout) = sas.into_parts();

    // Build the Arrow schema from SAS column metadata.
    let n_cols = layout.columns.len();
    let mut kinds = Vec::with_capacity(n_cols);
    let mut fields = Vec::with_capacity(n_cols);
    for (i, col) in layout.columns.iter().enumerate() {
        let name = layout
            .header
            .metadata
            .variables
            .get(i)
            .map(|v| v.name.clone())
            .unwrap_or_else(|| format!("col{i}"));
        let dt = match col.kind {
            ColumnKind::Character => DataType::Utf8,
            ColumnKind::Numeric(NumericKind::Double) => DataType::Float64,
            ColumnKind::Numeric(NumericKind::Date) => DataType::Date32,
            ColumnKind::Numeric(NumericKind::DateTime) => {
                DataType::Timestamp(TimeUnit::Microsecond, None)
            }
            ColumnKind::Numeric(NumericKind::Time) => DataType::Time64(TimeUnit::Microsecond),
        };
        kinds.push(col.kind);
        fields.push(Field::new(name, dt, true));
    }
    let schema: SchemaRef = Arc::new(Schema::new(fields));

    let props = Arc::new(
        WriterProperties::builder()
            .set_compression(Compression::ZSTD(ZstdLevel::try_new(zstd_level)?))
            .set_statistics_enabled(EnabledStatistics::None)
            .set_dictionary_enabled(false)
            .build(),
    );
    let parquet_schema: Arc<SchemaDescriptor> = Arc::new(
        ArrowSchemaConverter::new()
            .with_coerce_types(props.coerce_types())
            .convert(&schema)?,
    );

    let workers = thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let (rg_tx, rg_rx) = bounded::<(usize, RecordBatch)>(workers);
    let (chunk_tx, chunk_rx) = bounded::<(usize, Vec<ArrowColumnChunk>)>(workers);

    // Encoder pool: heavy work (parquet encoding + zstd) happens here.
    let mut encoder_handles = Vec::new();
    for _ in 0..workers {
        let rg_rx = rg_rx.clone();
        let chunk_tx = chunk_tx.clone();
        let schema = schema.clone();
        let parquet_schema = parquet_schema.clone();
        let props = props.clone();
        encoder_handles.push(thread::spawn(move || -> Result<(), AnyError> {
            while let Ok((idx, batch)) = rg_rx.recv() {
                let mut writers = get_column_writers(&parquet_schema, &props, &schema)?;
                for ((writer, field), array) in writers
                    .iter_mut()
                    .zip(schema.fields())
                    .zip(batch.columns())
                {
                    for leaf in compute_leaves(field, array)? {
                        writer.write(&leaf)?;
                    }
                }
                let chunks = writers
                    .into_iter()
                    .map(|w| w.close())
                    .collect::<Result<Vec<_>, _>>()?;
                chunk_tx.send((idx, chunks))?;
            }
            Ok(())
        }));
    }
    drop(rg_rx);
    drop(chunk_tx);

    // Writer thread: append encoded row groups in original order.
    let writer_handle = {
        let out = File::create(&dst)?;
        let root = parquet_schema.root_schema_ptr();
        let props = props.clone();
        thread::spawn(move || -> Result<u64, AnyError> {
            let mut writer = SerializedFileWriter::new(out, root, props)?;
            let mut pending: BTreeMap<usize, Vec<ArrowColumnChunk>> = BTreeMap::new();
            let mut next = 0usize;
            let mut rows = 0u64;
            while let Ok((idx, chunks)) = chunk_rx.recv() {
                pending.insert(idx, chunks);
                while let Some(chunks) = pending.remove(&next) {
                    let mut rg = writer.next_row_group()?;
                    for chunk in chunks {
                        chunk.append_to_row_group(&mut rg)?;
                    }
                    rows += rg.close()?.num_rows() as u64;
                    next += 1;
                }
            }
            writer.close()?;
            Ok(rows)
        })
    };

    // Reader loop (this thread): decode SAS pages into Arrow arrays.
    let mut it = layout.row_iterator(&mut file)?;
    let mut acc: Vec<Vec<ArrayRef>> = vec![Vec::new(); n_cols];
    let mut acc_rows = 0usize;
    let mut rg_index = 0usize;

    let flush = |acc: &mut Vec<Vec<ArrayRef>>,
                 acc_rows: &mut usize,
                 rg_index: &mut usize|
     -> Result<(), AnyError> {
        if *acc_rows == 0 {
            return Ok(());
        }
        let cols: Vec<ArrayRef> = acc
            .iter_mut()
            .map(|parts| {
                let refs: Vec<&dyn arrow_array::Array> =
                    parts.iter().map(|a| a.as_ref()).collect();
                let out = if refs.len() == 1 {
                    parts[0].clone()
                } else {
                    concat(&refs)?
                };
                parts.clear();
                Ok::<_, AnyError>(out)
            })
            .collect::<Result<_, _>>()?;
        let batch = RecordBatch::try_new(schema.clone(), cols)?;
        rg_tx.send((*rg_index, batch))?;
        *rg_index += 1;
        *acc_rows = 0;
        Ok(())
    };

    let debug = std::env::var("SASQ_DEBUG").is_ok();
    let decode_only = std::env::var("SASQ_DECODE_ONLY").is_ok();
    let raw_only = std::env::var("SASQ_RAW_ONLY").is_ok();
    let mut n_batches = 0usize;
    let t_read = Instant::now();
    while let Some(batch) = it.next_columnar_batch_contiguous(rg_rows - acc_rows)? {
        let n = batch.row_count;
        if n == 0 {
            break;
        }
        n_batches += 1;
        if raw_only {
            continue; // measure pure page iteration cost
        }
        // Row-major single pass: SAS rows are row-oriented, so per-column
        // iteration re-scans the whole batch once per column (43x memory
        // traffic, ~5s/GB). One pass with per-column builders is ~5x faster.
        let cols: Vec<_> = (0..n_cols)
            .map(|i| batch.column(i).ok_or("column index out of range"))
            .collect::<Result<_, _>>()?;
        let mut num_vals: Vec<Vec<u64>> = kinds
            .iter()
            .map(|k| match k {
                ColumnKind::Numeric(_) => Vec::with_capacity(n),
                ColumnKind::Character => Vec::new(),
            })
            .collect();
        let mut num_nulls: Vec<NullBufferBuilder> =
            (0..n_cols).map(|_| NullBufferBuilder::new(n)).collect();
        let mut str_builders: Vec<Option<StringBuilder>> = kinds
            .iter()
            .map(|k| match k {
                ColumnKind::Character => Some(StringBuilder::with_capacity(n, n * 8)),
                ColumnKind::Numeric(_) => None,
            })
            .collect();

        for row in 0..n {
            for (i, kind) in kinds.iter().enumerate() {
                match kind {
                    ColumnKind::Character => {
                        let b = str_builders[i].as_mut().expect("string builder");
                        match cols[i].iter_strings_range(row, 1).next().flatten() {
                            Some(v) => b.append_value(v.as_ref()),
                            None => b.append_null(),
                        }
                    }
                    ColumnKind::Numeric(_) => match cols[i]
                        .iter_numeric_bits_range(row, 1)
                        .next()
                        .flatten()
                    {
                        Some(bits) => {
                            num_vals[i].push(bits);
                            num_nulls[i].append_non_null();
                        }
                        None => {
                            num_vals[i].push(0);
                            num_nulls[i].append_null();
                        }
                    },
                }
            }
        }

        for (i, kind) in kinds.iter().enumerate() {
            let array: ArrayRef = match kind {
                ColumnKind::Character => {
                    Arc::new(str_builders[i].take().expect("string builder").finish())
                }
                ColumnKind::Numeric(nk) => {
                    let bits = std::mem::take(&mut num_vals[i]);
                    let nulls = num_nulls[i].finish();
                    match nk {
                        NumericKind::Double => {
                            let vals: Vec<f64> =
                                bits.into_iter().map(f64::from_bits).collect();
                            Arc::new(Float64Array::new(vals.into(), nulls))
                        }
                        NumericKind::Date => {
                            let vals: Vec<i32> = bits
                                .into_iter()
                                .map(|b| f64::from_bits(b) as i32 - SAS_EPOCH_DAYS)
                                .collect();
                            Arc::new(Date32Array::new(vals.into(), nulls))
                        }
                        NumericKind::DateTime => {
                            let vals: Vec<i64> = bits
                                .into_iter()
                                .map(|b| {
                                    ((f64::from_bits(b) - SAS_EPOCH_SECS as f64) * 1e6).round()
                                        as i64
                                })
                                .collect();
                            Arc::new(TimestampMicrosecondArray::new(vals.into(), nulls))
                        }
                        NumericKind::Time => {
                            let vals: Vec<i64> = bits
                                .into_iter()
                                .map(|b| (f64::from_bits(b) * 1e6).round() as i64)
                                .collect();
                            Arc::new(Time64MicrosecondArray::new(vals.into(), nulls))
                        }
                    }
                }
            };
            acc[i].push(array);
        }
        acc_rows += n;
        if acc_rows >= rg_rows {
            if decode_only {
                for parts in &mut acc {
                    parts.clear();
                }
                acc_rows = 0;
            } else {
                flush(&mut acc, &mut acc_rows, &mut rg_index)?;
            }
        }
    }
    if !decode_only {
        flush(&mut acc, &mut acc_rows, &mut rg_index)?;
    }
    drop(rg_tx);
    if debug {
        eprintln!(
            "reader thread done: {:.2?}, {} batches (avg {} rows/batch)",
            t_read.elapsed(),
            n_batches,
            if n_batches > 0 { 2_700_000 / n_batches.max(1) } else { 0 }
        );
    }

    for h in encoder_handles {
        h.join().map_err(|_| "encoder panicked")??;
    }
    let rows = writer_handle.join().map_err(|_| "writer panicked")??;
    eprintln!("sasq: {} rows in {:.2?}", rows, t0.elapsed());
    Ok(())
}
