/*
 * DNA Alignment Workflow
 * 
 * Handles alignment for different platforms
 * TODO: add support for bowtie2? Some people still use it
 */

include { BWA_MEM               } from '../modules/local/bwa/mem/main'
include { MINIMAP2_ALIGN        } from '../modules/local/minimap2/align/main'
include { PBMM2_ALIGN           } from '../modules/local/pbmm2/align/main'
include { SAMTOOLS_SORT         } from '../modules/local/samtools/sort/main'
include { SAMTOOLS_INDEX        } from '../modules/local/samtools/index/main'
include { GATK4_MARKDUPLICATES  } from '../modules/local/gatk4/markduplicates/main'
include { SAMTOOLS_STATS        } from '../modules/local/samtools/stats/main'
include { SAMTOOLS_IDXSTATS     } from '../modules/local/samtools/idxstats/main'
include { SAMTOOLS_FLAGSTAT     } from '../modules/local/samtools/flagstat/main'

workflow ALIGN_DNA {
    
    take:
    ch_tumor_reads    // channel: [ meta, [ reads ] ]
    ch_normal_reads   // channel: [ meta, [ reads ] ]
    bwa_index         // channel: /path/to/bwa/index/
    reference_dict    // channel: /path/to/reference.dict
    reference_fai     // channel: /path/to/reference.fai
    
    main:
    ch_versions = Channel.empty()
    
    // separate by platform
    // FIXME: this is getting repetitive, should refactor
    ch_tumor_illumina = ch_tumor_reads.filter { meta, reads -> meta.platform == 'illumina' }
    ch_tumor_pacbio   = ch_tumor_reads.filter { meta, reads -> meta.platform == 'pacbio' }
    ch_tumor_ont      = ch_tumor_reads.filter { meta, reads -> meta.platform == 'ont' }
    
    ch_normal_illumina = ch_normal_reads.filter { meta, reads -> meta.platform == 'illumina' }
    ch_normal_pacbio   = ch_normal_reads.filter { meta, reads -> meta.platform == 'pacbio' }
    ch_normal_ont      = ch_normal_reads.filter { meta, reads -> meta.platform == 'ont' }
    
    /*
    ================================================================================
        ILLUMINA ALIGNMENT
    ================================================================================
    */
    
    // Align Illumina reads with BWA
    BWA_MEM(
        ch_tumor_illumina,
        bwa_index,
        true  // sort = true
    )
    ch_versions = ch_versions.mix(BWA_MEM.out.versions.first())
    
    BWA_MEM(
        ch_normal_illumina,
        bwa_index,
        true
    )
    
    // Mark duplicates for Illumina
    GATK4_MARKDUPLICATES(
        BWA_MEM.out.bam,
        reference_dict,
        reference_fai
    )
    ch_versions = ch_versions.mix(GATK4_MARKDUPLICATES.out.versions.first())
    
    ch_illumina_final_bam = GATK4_MARKDUPLICATES.out.bam
    
    /*
    ================================================================================
        PACBIO ALIGNMENT
    ================================================================================
    */
    
    // Align PacBio reads with pbmm2
    PBMM2_ALIGN(
        ch_tumor_pacbio.mix(ch_normal_pacbio),
        bwa_index  // pbmm2 can use same index format
    )
    ch_versions = ch_versions.mix(PBMM2_ALIGN.out.versions.first())
    
    ch_pacbio_final_bam = PBMM2_ALIGN.out.bam
    
    /*
    ================================================================================
        ONT ALIGNMENT
    ================================================================================
    */
    
    // Align ONT reads with minimap2
    MINIMAP2_ALIGN(
        ch_tumor_ont.mix(ch_normal_ont),
        bwa_index.map { it -> file(it).parent + '/reference.fa' }  // Get reference from index
    )
    ch_versions = ch_versions.mix(MINIMAP2_ALIGN.out.versions.first())
    
    // Sort and index ONT alignments
    SAMTOOLS_SORT(
        MINIMAP2_ALIGN.out.bam
    )
    ch_versions = ch_versions.mix(SAMTOOLS_SORT.out.versions.first())
    
    ch_ont_final_bam = SAMTOOLS_SORT.out.bam
    
    /*
    ================================================================================
        COMBINE AND INDEX ALL ALIGNMENTS
    ================================================================================
    */
    
    // Combine all final BAMs
    ch_all_bam = ch_illumina_final_bam
        .mix(ch_pacbio_final_bam)
        .mix(ch_ont_final_bam)
    
    // Index all BAMs
    SAMTOOLS_INDEX(ch_all_bam)
    ch_versions = ch_versions.mix(SAMTOOLS_INDEX.out.versions.first())
    
    // Combine BAM and BAI
    ch_bam_bai = ch_all_bam
        .join(SAMTOOLS_INDEX.out.bai, by: [0])
    
    /*
    ================================================================================
        QC METRICS
    ================================================================================
    */
    
    // Collect alignment statistics
    SAMTOOLS_STATS(
        ch_bam_bai,
        reference_fai
    )
    ch_versions = ch_versions.mix(SAMTOOLS_STATS.out.versions.first())
    
    SAMTOOLS_FLAGSTAT(ch_bam_bai)
    ch_versions = ch_versions.mix(SAMTOOLS_FLAGSTAT.out.versions.first())
    
    SAMTOOLS_IDXSTATS(ch_bam_bai)
    ch_versions = ch_versions.mix(SAMTOOLS_IDXSTATS.out.versions.first())
    
    // Separate tumor and normal for output
    ch_tumor_bam = ch_bam_bai.filter { meta, bam, bai -> 
        meta.id.contains('tumor')
    }
    
    ch_normal_bam = ch_bam_bai.filter { meta, bam, bai -> 
        meta.id.contains('normal')
    }
    
    emit:
    tumor_bam    = ch_tumor_bam
    normal_bam   = ch_normal_bam
    stats        = SAMTOOLS_STATS.out.stats
    flagstat     = SAMTOOLS_FLAGSTAT.out.flagstat
    idxstats     = SAMTOOLS_IDXSTATS.out.idxstats
    versions     = ch_versions
}
