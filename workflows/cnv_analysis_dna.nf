// DNA CNV calling workflow
// This is where the magic happens (or breaks)

include { CNVKIT_BATCH           } from '../modules/local/cnvkit/batch/main'
include { SEVERUS                } from '../modules/local/severus/main'
include { GATK4_COLLECTREADCOUNTS } from '../modules/local/gatk4/collectreadcounts/main'
include { GATK4_DENOISECOUNTS    } from '../modules/local/gatk4/denoisecounts/main'
include { GATK4_MODELSEGMENTS    } from '../modules/local/gatk4/modelsegments/main'
include { GATK4_CALLCOPYNUMBERSEGMENTS } from '../modules/local/gatk4/callcopynumbersegments/main'
include { MERGE_CNV_CALLS        } from '../modules/local/merge_cnv_calls/main'

workflow CNV_ANALYSIS_DNA {
    
    take:
    ch_tumor_bam     // channel: [ meta, bam, bai ]
    ch_normal_bam    // channel: [ meta, bam, bai ]
    reference_dict   // channel: /path/to/reference.dict
    reference_fai    // channel: /path/to/reference.fai
    intervals        // channel: /path/to/intervals.bed
    pon              // channel: /path/to/panel_of_normals (optional)
    
    main:
    ch_versions = Channel.empty()
    ch_qc_files = Channel.empty()
    
    // Match tumor-normal pairs
    // this matching logic is a mess but it works... mostly
    ch_matched_pairs = ch_tumor_bam
        .map { meta, bam, bai -> 
            def patient = meta.patient ?: meta.id.replaceAll('_tumor', '')
            [patient, meta, bam, bai]
        }
        .combine(
            ch_normal_bam.map { meta, bam, bai -> 
                def patient = meta.patient ?: meta.id.replaceAll('_normal', '')
                [patient, meta, bam, bai]
            },
            by: 0
        )
        .map { patient, tumor_meta, tumor_bam, tumor_bai, normal_meta, normal_bam, normal_bai ->
            def meta = tumor_meta.clone()
            meta.patient = patient
            [meta, tumor_bam, tumor_bai, normal_bam, normal_bai]
        }
    
    // Separate by platform
    ch_illumina_pairs = ch_matched_pairs.filter { meta, t_bam, t_bai, n_bam, n_bai -> 
        meta.platform == 'illumina' 
    }
    
    ch_longread_pairs = ch_matched_pairs.filter { meta, t_bam, t_bai, n_bam, n_bai -> 
        meta.platform in ['pacbio', 'ont']
    }
    
    /*
    ================================================================================
        ILLUMINA CNV ANALYSIS
    ================================================================================
    */
    
    // CNVkit for Illumina WGS/WES
    CNVKIT_BATCH(
        ch_illumina_pairs,
        reference_dict.map { it -> file(it).parent + '/reference.fa' }
    )
    ch_versions = ch_versions.mix(CNVKIT_BATCH.out.versions.first())
    ch_qc_files = ch_qc_files.mix(CNVKIT_BATCH.out.qc_files)
    
    // GATK CNV pipeline for Illumina
    ch_illumina_bams = ch_illumina_pairs
        .multiMap { meta, t_bam, t_bai, n_bam, n_bai ->
            tumor: [meta, t_bam, t_bai]
            normal: [meta, n_bam, n_bai]
        }
    
    // Collect read counts
    GATK4_COLLECTREADCOUNTS(
        ch_illumina_bams.tumor.mix(ch_illumina_bams.normal),
        intervals,
        reference_dict,
        reference_fai
    )
    ch_versions = ch_versions.mix(GATK4_COLLECTREADCOUNTS.out.versions.first())
    
    // Denoise read counts
    ch_tumor_counts = GATK4_COLLECTREADCOUNTS.out.counts
        .filter { meta, counts -> meta.id.contains('tumor') }
    
    ch_normal_counts = GATK4_COLLECTREADCOUNTS.out.counts
        .filter { meta, counts -> meta.id.contains('normal') }
    
    GATK4_DENOISECOUNTS(
        ch_tumor_counts,
        pon ?: ch_normal_counts.collect { it[1] }  // Use normals as PON if not provided
    )
    ch_versions = ch_versions.mix(GATK4_DENOISECOUNTS.out.versions.first())
    
    // Model segments
    GATK4_MODELSEGMENTS(
        GATK4_DENOISECOUNTS.out.denoised,
        ch_normal_counts.map { meta, counts -> counts }.ifEmpty([])
    )
    ch_versions = ch_versions.mix(GATK4_MODELSEGMENTS.out.versions.first())
    
    // Call copy number segments
    GATK4_CALLCOPYNUMBERSEGMENTS(
        GATK4_MODELSEGMENTS.out.segments
    )
    ch_versions = ch_versions.mix(GATK4_CALLCOPYNUMBERSEGMENTS.out.versions.first())
    
    ch_illumina_cnv = CNVKIT_BATCH.out.cnv_calls
        .join(GATK4_CALLCOPYNUMBERSEGMENTS.out.called_segments, by: [0])
        .map { meta, cnvkit_calls, gatk_calls ->
            [meta, [cnvkit: cnvkit_calls, gatk: gatk_calls]]
        }
    
    /*
    ================================================================================
        LONG-READ CNV ANALYSIS
    ================================================================================
    */
    
    // Severus for PacBio/ONT
    SEVERUS(
        ch_longread_pairs,
        params.vntr_bed ? file(params.vntr_bed) : file("${projectDir}/assets/vntr_regions.bed")
    )
    ch_versions = ch_versions.mix(SEVERUS.out.versions.first())
    
    ch_longread_cnv = SEVERUS.out.cnv_calls
    
    /*
    ================================================================================
        MERGE AND ANNOTATE CNV CALLS
    ================================================================================
    */
    
    // Combine all CNV calls
    ch_all_cnv = ch_illumina_cnv.mix(ch_longread_cnv)
    
    // Merge CNV calls from different tools
    MERGE_CNV_CALLS(
        ch_all_cnv,
        reference_dict
    )
    ch_versions = ch_versions.mix(MERGE_CNV_CALLS.out.versions.first())
    
    emit:
    cnv_calls    = MERGE_CNV_CALLS.out.merged_cnv
    raw_calls    = ch_all_cnv
    qc           = ch_qc_files
    versions     = ch_versions
}
