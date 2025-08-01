/*
================================================================================
    PREPARE REFERENCES WORKFLOW
================================================================================
    Prepare all reference files needed for the pipeline
--------------------------------------------------------------------------------
*/

include { BWA_INDEX              } from '../modules/local/bwa/index/main'
include { STAR_GENOMEGENERATE    } from '../modules/local/star/genomegenerate/main'
include { SAMTOOLS_FAIDX         } from '../modules/local/samtools/faidx/main'
include { GATK4_CREATESEQUENCEDICT } from '../modules/local/gatk4/createsequencedict/main'
include { GATK4_PREPROCESSINTERVALS } from '../modules/local/gatk4/preprocessintervals/main'
include { CREATE_INTERVALS_BED   } from '../modules/local/create_intervals_bed/main'

workflow PREPARE_REFERENCES {
    
    take:
    reference_fasta
    gtf_file
    
    main:
    ch_versions = Channel.empty()
    
    // Index reference genome for BWA
    BWA_INDEX(reference_fasta)
    ch_versions = ch_versions.mix(BWA_INDEX.out.versions)
    
    // Generate STAR index for RNA-seq alignment
    STAR_GENOMEGENERATE(
        reference_fasta,
        gtf_file
    )
    ch_versions = ch_versions.mix(STAR_GENOMEGENERATE.out.versions)
    
    // Create reference index and dict
    SAMTOOLS_FAIDX(reference_fasta)
    ch_versions = ch_versions.mix(SAMTOOLS_FAIDX.out.versions)
    
    GATK4_CREATESEQUENCEDICT(reference_fasta)
    ch_versions = ch_versions.mix(GATK4_CREATESEQUENCEDICT.out.versions)
    
    // Create intervals for parallel processing
    CREATE_INTERVALS_BED(
        reference_fasta,
        SAMTOOLS_FAIDX.out.fai
    )
    
    // Preprocess intervals for GATK CNV
    GATK4_PREPROCESSINTERVALS(
        reference_fasta,
        SAMTOOLS_FAIDX.out.fai,
        GATK4_CREATESEQUENCEDICT.out.dict,
        CREATE_INTERVALS_BED.out.intervals
    )
    ch_versions = ch_versions.mix(GATK4_PREPROCESSINTERVALS.out.versions)
    
    emit:
    bwa_index    = BWA_INDEX.out.index
    star_index   = STAR_GENOMEGENERATE.out.index
    reference_fai = SAMTOOLS_FAIDX.out.fai
    reference_dict = GATK4_CREATESEQUENCEDICT.out.dict
    intervals    = GATK4_PREPROCESSINTERVALS.out.intervals
    gtf          = gtf_file
    pon          = Channel.empty()  // Placeholder for panel of normals
    versions     = ch_versions
}
