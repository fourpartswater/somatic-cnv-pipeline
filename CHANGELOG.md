# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]
- Manta integration
- Better handling of polyploid samples
- Fix GATK crash on chromosome Y

## [1.0.0] - 2024-02-15

### Added
- AWS Batch support
- MultiQC reports
- RNA CNV calling with CaSpER (experimental)

### Fixed
- CNVkit memory issues on WGS samples
- Race condition in reference indexing
- pbmm2 compatibility with BWA index

### Changed
- Switched from TSV to CSV for samplesheet
- Bumped minimum Nextflow version to 23.04.0

### Known Issues
- GATK interval padding broken (set to 0 by default)
- Severus fails on very long reads
- Spaces in sample names cause errors

## [0.5.0] - 2023-12-01

### Added
- Long read support (PacBio and ONT)
- Severus for long-read CNV calling
- Parallel processing of samples

### Changed
- Rewrite in DSL2
- New samplesheet format

### Removed
- DSL1 code
- Support for Nextflow <22.10.0

## [0.4.2] - 2023-10-15

### Fixed
- STAR index generation for large genomes
- Memory allocation for GATK

## [0.4.1] - 2023-09-20

### Fixed
- Docker permissions issue
- Singularity bind paths

## [0.4.0] - 2023-09-01

### Added
- AWS Batch configuration
- S3 support for inputs/outputs

### Known Issues
- Spot instances compatibility
- Manual bucket creation required

## [0.3.0] - 2023-07-15

### Added
- CNVkit for WES/WGS
- Scatter plots

### Fixed
- BWA index detection

## [0.2.0] - 2023-06-01

### Added
- GATK CollectReadCounts
- GATK DenoiseReadCounts
- Panel of normals support

### Issues
- Performance issues on large cohorts
- Random crashes

## [0.1.0] - 2023-05-01

### Added
- BWA alignment
- FastQC
- MultiQC

### Notes
- Initial release
- Tested on Illumina data only