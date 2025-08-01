#!/usr/bin/env nextflow
/*
 * Somatic CNV Pipeline
 * 
 * Version history:
 * 0.1 (2023-05-01): Basic alignment working
 * 0.2 (2023-06-01): Added GATK CNV (so slow...)
 * 0.3 (2023-07-15): CNVkit integration
 * 0.4 (2023-09-01): AWS support (beta)
 * 0.5 (2023-12-01): Rewrote everything in DSL2
 * 1.0 (2024-02-15): Added long-read support
 * 
 * TODO: add more CNV callers (Manta? LUMPY?)
 * TODO: better handling of RNA samples
 * FIXME: memory usage is out of control on WGS
 */

nextflow.enable.dsl = 2

// print some info
// had to disable the fancy logo, was causing issues on some terminals

def logo = NfcoreTemplate.logo(workflow, params.monochrome_logs)
def citation = '\n' + WorkflowMain.citation(workflow) + '\n'
def summary = WorkflowMain.summary(workflow, params)

// Print pipeline info
log.info logo + summary + citation

// Check input parameters
WorkflowMain.initialise(workflow, params, log)

// imports - getting a bit messy, need to reorganize at some point
include { FASTQC                    } from './modules/local/fastqc/main'
include { MULTIQC                   } from './modules/local/multiqc/main'

// Reference preparation
include { PREPARE_REFERENCES        } from './workflows/prepare_references'

// Alignment workflows
include { ALIGN_DNA                 } from './workflows/align_dna'
include { ALIGN_RNA                 } from './workflows/align_rna'

// CNV analysis workflows
include { CNV_ANALYSIS_DNA          } from './workflows/cnv_analysis_dna'
include { CNV_ANALYSIS_RNA          } from './workflows/cnv_analysis_rna'

// Reporting
include { GENERATE_REPORT           } from './modules/local/reporting/main'

/*
================================================================================
    IMPORT NF-CORE MODULES
================================================================================
*/

include { CUSTOM_DUMPSOFTWAREVERSIONS } from './modules/nf-core/custom/dumpsoftwareversions/main'

/*
================================================================================
    RUN MAIN WORKFLOW
================================================================================
*/

workflow SOMATIC_CNV_PIPELINE {
    
    ch_versions = Channel.empty()
    ch_multiqc_files = Channel.empty()
    
    // Read and validate samplesheet
    Channel
        .fromPath(params.input)
        .splitCsv(header: true, sep: ',', strip: true)
        .map { create_input_channels(it) }
        .set { ch_input }
    
    // Separate tumor and normal samples
    ch_input
        .map { meta, tumor_reads, normal_reads ->
            [meta, tumor_reads]
        }
        .set { ch_tumor_reads }
    
    ch_input
        .filter { meta, tumor_reads, normal_reads -> 
            normal_reads != null && normal_reads[0] != ''
        }
        .map { meta, tumor_reads, normal_reads ->
            [meta, normal_reads]
        }
        .set { ch_normal_reads }
    
    // prepare references
    // TODO: add check if indices already exist to save time
    PREPARE_REFERENCES()
    ch_versions = ch_versions.mix(PREPARE_REFERENCES.out.versions)
    
    // run fastqc unless skipped
    // HACK: fastqc sometimes hangs on large files, might need to add timeout
    if (!params.skip_fastqc) {
        FASTQC(
            ch_tumor_reads
        )
        ch_versions = ch_versions.mix(FASTQC.out.versions.first())
        ch_multiqc_files = ch_multiqc_files.mix(FASTQC.out.zip.collect{it[1]})
    }
    
    /*
    ================================================================================
        SUBWORKFLOW: Alignment based on data type
    ================================================================================
    */
    
    // DNA alignment workflow
    ch_tumor_reads
        .filter { meta, reads -> meta.datatype == 'dna' }
        .set { ch_dna_reads }
    
    ch_normal_reads
        .filter { meta, reads -> meta.datatype == 'dna' }
        .set { ch_normal_dna_reads }
    
    ALIGN_DNA(
        ch_dna_reads,
        ch_normal_dna_reads,
        PREPARE_REFERENCES.out.bwa_index,
        PREPARE_REFERENCES.out.reference_dict,
        PREPARE_REFERENCES.out.reference_fai
    )
    ch_versions = ch_versions.mix(ALIGN_DNA.out.versions)
    
    // RNA alignment workflow
    ch_tumor_reads
        .filter { meta, reads -> meta.datatype == 'rna' }
        .set { ch_rna_reads }
    
    ch_normal_reads
        .filter { meta, reads -> meta.datatype == 'rna' }
        .set { ch_normal_rna_reads }
    
    ALIGN_RNA(
        ch_rna_reads,
        ch_normal_rna_reads,
        PREPARE_REFERENCES.out.star_index,
        PREPARE_REFERENCES.out.reference_dict,
        PREPARE_REFERENCES.out.gtf
    )
    ch_versions = ch_versions.mix(ALIGN_RNA.out.versions)
    
    /*
    ================================================================================
        SUBWORKFLOW: CNV Analysis
    ================================================================================
    */
    
    // DNA CNV analysis
    CNV_ANALYSIS_DNA(
        ALIGN_DNA.out.tumor_bam,
        ALIGN_DNA.out.normal_bam,
        PREPARE_REFERENCES.out.reference_dict,
        PREPARE_REFERENCES.out.reference_fai,
        PREPARE_REFERENCES.out.intervals,
        PREPARE_REFERENCES.out.pon
    )
    ch_versions = ch_versions.mix(CNV_ANALYSIS_DNA.out.versions)
    ch_multiqc_files = ch_multiqc_files.mix(CNV_ANALYSIS_DNA.out.qc)
    
    // RNA CNV analysis
    CNV_ANALYSIS_RNA(
        ALIGN_RNA.out.tumor_bam,
        ALIGN_RNA.out.quantification,
        PREPARE_REFERENCES.out.gtf,
        PREPARE_REFERENCES.out.reference_dict
    )
    ch_versions = ch_versions.mix(CNV_ANALYSIS_RNA.out.versions)
    
    /*
    ================================================================================
        MODULE: Generate comprehensive report
    ================================================================================
    */
    
    GENERATE_REPORT(
        CNV_ANALYSIS_DNA.out.cnv_calls,
        CNV_ANALYSIS_RNA.out.cnv_calls,
        ch_multiqc_files.collect()
    )
    
    /*
    ================================================================================
        MODULE: Dump software versions
    ================================================================================
    */
    
    CUSTOM_DUMPSOFTWAREVERSIONS(
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )
    
    /*
    ================================================================================
        MODULE: MultiQC
    ================================================================================
    */
    
    workflow_summary = WorkflowMain.summary(workflow, params)
    ch_workflow_summary = Channel.value(workflow_summary)
    
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.versions.collect())
    
    MULTIQC(
        ch_multiqc_files.collect()
    )
    multiqc_report = MULTIQC.out.report.toList()
    ch_versions    = ch_versions.mix(MULTIQC.out.versions)
}

/*
================================================================================
    COMPLETION SUMMARY
================================================================================
*/

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.summary(workflow, params, log)
    if (params.hook_url) {
        NfcoreTemplate.adaptivecard(workflow, params, summary_params, projectDir, log)
    }
}

/*
================================================================================
    FUNCTIONS
================================================================================
*/

def create_input_channels(LinkedHashMap row) {
    // quick validation - should probably make this more robust later
    if (!row.sample) {
        error "Missing sample name in samplesheet"
    }
    
    // check platform
    def valid_platforms = ['illumina', 'pacbio', 'ont']
    if (!row.platform || !valid_platforms.contains(row.platform.toLowerCase())) {
        error "Platform '${row.platform}' not supported. Use: ${valid_platforms.join(', ')}"
    }
    
    def meta = [:]
    meta.id = row.sample.replaceAll('[^a-zA-Z0-9_-]', '_')  // sanitize just in case
    meta.patient = row.patient ?: row.sample
    meta.platform = row.platform.toLowerCase()
    meta.datatype = row.datatype?.toLowerCase() ?: 'dna'  // default to dna
    
    // FIXME: this validation is getting out of hand
    // maybe just trust the user knows what they're doing?
    
    // grab tumor files
    def tumor_reads = []
    if (row.tumor_fastq1) {
        // println "DEBUG: processing tumor ${row.tumor_fastq1}"
        tumor_reads = [file(row.tumor_fastq1, checkIfExists: true)]
        if (row.tumor_fastq2 && row.tumor_fastq2 != '') {
            tumor_reads << file(row.tumor_fastq2, checkIfExists: true)
        }
    } else {
        error "Need at least tumor_fastq1 for ${row.sample}"
    }
    
    // grab normal files if they exist
    def normal_reads = []
    if (row.normal_fastq1 && row.normal_fastq1 != '') {
        normal_reads = [file(row.normal_fastq1, checkIfExists: true)]
        if (row.normal_fastq2 && row.normal_fastq2 != '') {
            normal_reads << file(row.normal_fastq2, checkIfExists: true)
        }
    }
    
    // warn about long-read paired end (common mistake)
    if (meta.platform in ['pacbio', 'ont'] && tumor_reads.size() > 1) {
        log.warn "WARNING: ${meta.platform} usually doesn't have paired-end reads. This might not work!"
    }
    
    // RNA without normal is fine, i guess
    if (meta.datatype == 'rna' && normal_reads.isEmpty()) {
        log.info "No normal for RNA sample ${row.sample} - running tumor-only"
    }
    
    return [meta, tumor_reads, normal_reads]
}

/*
================================================================================
    THE END
================================================================================
*/
