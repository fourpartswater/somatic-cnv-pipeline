# Somatic CNV Analysis Pipeline

[![Nextflow](https://img.shields.io/badge/nextflow%20DSL2-%E2%89%A523.04.0-23aa62.svg)](https://www.nextflow.io/)
[![run with docker](https://img.shields.io/badge/run%20with-docker-0db7ed?labelColor=000000&logo=docker)](https://www.docker.com/)
[![run with singularity](https://img.shields.io/badge/run%20with-singularity-1d355c.svg?labelColor=000000)](https://sylabs.io/docs/)

## What is this?

A Nextflow pipeline for calling somatic CNVs from tumor/normal pairs. Supports Illumina, PacBio, and ONT data (in theory - ONT is still experimental). 

Started this because I needed something that could handle multiple platforms and the existing pipelines were either too rigid or kept breaking.

## What it does

1. QC with FastQC (unless you skip it)
2. Alignment:
   - Illumina → BWA-MEM
   - PacBio → pbmm2 
   - ONT → minimap2
   - RNA → STAR (or minimap2 for long reads)
3. CNV calling:
   - CNVkit for short reads (works pretty well)
   - GATK CNV (slower but sometimes better?)
   - Severus for long reads (new tool, still testing)
   - CaSpER for RNA (experimental!)
4. Tries to merge the calls into something useful
5. Makes a MultiQC report

## Quick Start

1. Install [`Nextflow`](https://www.nextflow.io/docs/latest/getstarted.html#installation) (`>=23.04.0`)

2. Install [`Docker`](https://docs.docker.com/engine/installation/), [`Singularity`](https://www.sylabs.io/guides/3.0/user-guide/), or [`Podman`](https://podman.io/)

3. Download the pipeline:

   ```bash
   git clone https://github.com/fourpartswater/somatic-cnv-pipeline
   cd somatic-cnv-pipeline
   ```

4. Test the pipeline:

   ```bash
   nextflow run main.nf -profile test,docker
   ```

5. Run with your data:

   ```bash
   nextflow run main.nf \
       -profile docker \
       --input samplesheet.csv \
       --reference hg38.fa \
       --gtf hg38.gtf \
       --outdir results
   ```

## Input Samplesheet Format

Create a CSV file with the following columns:

```csv
sample,patient,tumor_fastq1,tumor_fastq2,normal_fastq1,normal_fastq2,platform,datatype
SAMPLE1,PATIENT1,tumor_R1.fq.gz,tumor_R2.fq.gz,normal_R1.fq.gz,normal_R2.fq.gz,illumina,dna
SAMPLE2,PATIENT2,tumor.fastq.gz,,normal.fastq.gz,,pacbio,dna
SAMPLE3,PATIENT3,tumor_R1.fq.gz,tumor_R2.fq.gz,,,illumina,rna
```

### Column Descriptions:
- **sample**: Unique sample identifier
- **patient**: Patient ID (for matching tumor-normal pairs)
- **tumor_fastq1/2**: Path to tumor FASTQ files
- **normal_fastq1/2**: Path to normal FASTQ files (optional for RNA)
- **platform**: `illumina`, `pacbio`, or `ont`
- **datatype**: `dna` or `rna`

## Pipeline Parameters

### Essential Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--input` | Path to input samplesheet CSV | None |
| `--reference` | Path to reference genome FASTA | None |
| `--gtf` | Path to gene annotation GTF | None |
| `--outdir` | Output directory | `./results` |

### Optional Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--intervals` | BED file for targeted regions | Whole genome |
| `--pon` | Panel of normals for GATK CNV | None |
| `--vntr_bed` | VNTR regions for Severus | Built-in |
| `--skip_fastqc` | Skip FastQC | `false` |
| `--skip_multiqc` | Skip MultiQC report | `false` |

### Resource Allocation

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--max_cpus` | Maximum CPUs | 16 |
| `--max_memory` | Maximum memory | 128.GB |
| `--max_time` | Maximum runtime | 240.h |

## Running on AWS Batch

The pipeline is optimized for AWS Batch execution:

```bash
nextflow run main.nf \
    -profile awsbatch \
    --input s3://my-bucket/samplesheet.csv \
    --outdir s3://my-bucket/results \
    --awsqueue my-batch-queue \
    --awsregion us-east-1
```

### AWS Setup Requirements:

1. **AWS Batch Compute Environment** with ECS-optimized AMI
2. **Job Queue** linked to compute environment  
3. **IAM Roles** with S3 and Batch permissions
4. **S3 Bucket** for work directory and outputs

See [AWS Batch configuration](docs/aws_batch.md) for detailed setup instructions.

## Output Directory Structure

```
results/
├── fastqc/              # FastQC reports
├── alignments/          # BAM files and indices
├── cnv/                 # CNV calls from each tool
│   ├── cnvkit/
│   ├── gatk/
│   └── severus/
├── quant/               # RNA quantification
├── integrated/          # Merged CNV calls
├── multiqc/             # MultiQC report
└── pipeline_info/       # Nextflow execution reports
```

## Pipeline Architecture

### Modular Design

The pipeline follows nf-core standards with modular organization:

```
somatic-cnv-pipeline/
├── main.nf              # Main workflow
├── nextflow.config      # Pipeline configuration
├── modules/             # Process definitions
│   └── local/           # Custom modules
├── workflows/           # Sub-workflows
├── conf/                # Configuration profiles
├── bin/                 # Helper scripts
└── assets/              # Pipeline resources
```

### Key Features

- **Multi-platform support**: Unified pipeline for Illumina, PacBio, and ONT
- **Containerization**: All tools in Docker/Singularity containers
- **Cloud-ready**: Optimized for AWS Batch with Fusion file transfers
- **Reproducible**: Version-controlled containers and nf-core standards
- **Scalable**: Dynamic resource allocation and parallel processing
- **Comprehensive**: Multiple CNV callers for cross-validation

## Advanced Configuration

### Custom Reference Files

```bash
nextflow run main.nf \
    --reference /path/to/genome.fa \
    --gtf /path/to/genes.gtf \
    --intervals /path/to/targets.bed \
    --pon /path/to/panel_of_normals.hdf5 \
    --vntr_bed /path/to/vntr_regions.bed
```

### Resource Optimization

For large datasets, adjust resource limits:

```bash
nextflow run main.nf \
    --max_cpus 64 \
    --max_memory 512.GB \
    --max_time 720.h
```

### Platform-Specific Options

```bash
# For WES data with CNVkit
nextflow run main.nf \
    --cnvkit_method hybrid \
    --intervals exome_targets.bed

# For long-read specific settings
nextflow run main.nf \
    --severus_min_support 3 \
    --minimap2_preset map-ont
```

## Troubleshooting

### Common Issues

1. **Memory errors**: Increase `--max_memory` or use AWS instance with more RAM
2. **Spot interruptions**: Use `--awsqueue` with on-demand instances for critical steps
3. **Missing indices**: Pipeline auto-generates indices, ensure reference has write permissions

### Debug Mode

```bash
nextflow run main.nf -profile debug,docker
```

### Resume Failed Runs

```bash
nextflow run main.nf -resume
```

## Citation

If you use this pipeline, please cite:

Clarke, P.C. (2025). Somatic CNV Analysis Pipeline: A comprehensive Nextflow workflow for multi-platform cancer genomics. https://github.com/fourpartswater/somatic-cnv-pipeline

## Contributions and Support

- **Issues**: https://github.com/fourpartswater/somatic-cnv-pipeline/issues
- **Documentation**: https://github.com/fourpartswater/somatic-cnv-pipeline/wiki
- **Updates**: Follow [@fourpartswater](https://github.com/fourpartswater) for updates

## License

This pipeline is released under the MIT License. See [LICENSE](LICENSE) for details.

---

**Author**: Peter Campbell Clarke | [peter@meneton.com](mailto:peter@meneton.com)
