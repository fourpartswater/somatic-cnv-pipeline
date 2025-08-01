# Known Issues

## Critical Issues

### GATK Interval Padding
- **Problem**: Setting `--interval-padding` > 0 can cause GATK CollectReadCounts to use excessive memory
- **Workaround**: Use `--interval-padding 0` for large datasets
- **Affects**: GATK CNV tools
- **Since**: GATK 4.2.0.0

### Spaces in File Names
- **Problem**: Pipeline fails if sample names or file paths contain spaces
- **Workaround**: Replace spaces with underscores in samplesheet
- **Affects**: Most pipeline stages

## Memory Issues

### CNVkit on WGS
- **Problem**: CNVkit can use >100GB RAM on high-coverage WGS samples
- **Workaround**: Increase memory allocation or downsample BAMs
- **Note**: Memory usage scales with coverage and genome size

### STAR Index Generation
- **Problem**: Requires approximately 10x genome size in RAM
- **Workaround**: Pre-generate indices on high-memory machine
- **Example**: Human genome needs ~32GB RAM

## Tool-Specific Issues

### BWA
- **Problem**: Can segfault with high thread counts on some systems
- **Workaround**: Limit to 8-16 threads
- **Note**: Possibly related to memory bandwidth limitations

### MultiQC
- **Problem**: Can hang or crash with very large datasets (>1000 samples)
- **Workaround**: Process in batches or increase memory
- **Affects**: Final report generation

### Docker
- **Problem**: Output files owned by root when using Docker
- **Workaround**: Use `docker.runOptions = '-u $(id -u):$(id -g)'` in config
- **Alternative**: Use Singularity

## Data Format Issues

### FASTQ Headers
- **Problem**: Some tools expect specific header formats (e.g., Illumina format)
- **Example**: `@A00123:456:HXXXXXXX:1:1101:1234:1000 1:N:0:ATCG` vs `@READ1`
- **Affects**: Older versions of some aligners

### Mixed Read Lengths
- **Problem**: Some tools struggle with mixed read lengths in same file
- **Affects**: Primarily long-read aligners
- **Workaround**: Separate by read length if necessary

## AWS-Specific

### S3 Transfer Timeouts
- **Problem**: Large files (>5GB) may timeout during S3 transfers
- **Workaround**: Enable S3 transfer acceleration or use multipart uploads
- **Config**: Set appropriate `aws.batch.maxTransferAttempts`

### Spot Instance Interruptions
- **Problem**: Spot termination can cause job failures
- **Workaround**: Use on-demand instances for long-running processes
- **Note**: Nextflow retry helps but not always sufficient

## Platform-Specific

### Long-Read Alignment
- **Problem**: Default parameters optimized for short reads may not work well
- **Workaround**: Use platform-specific presets (e.g., `map-pb` for PacBio)
- **Affects**: minimap2, other long-read tools

## Performance Issues

### GATK CNV Speed
- **Problem**: GATK CNV pipeline can be very slow on large cohorts
- **Workaround**: Process in smaller batches
- **Note**: Panel of normals creation is the bottleneck

### Reference Index Generation
- **Problem**: First run takes long time to generate all indices
- **Workaround**: Pre-generate indices and save them
- **Affects**: BWA, STAR, samtools indices