process BWA_MEM {
    tag "$meta.id"
    label 'process_high'
    
    // had issues with conda version, stick to containers
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/mulled-v2-8a259a362d5aa3b9e607b7a5c2cb2d4d61434e0f:b8d7a0db84d983cb01179c10d7e757cdcc388e42-0':
        'biocontainers/mulled-v2-8a259a362d5aa3b9e607b7a5c2cb2d4d61434e0f:b8d7a0db84d983cb01179c10d7e757cdcc388e42-0' }"
    
    input:
    tuple val(meta), path(reads)
    path(index)
    val(sort_bam)
    
    output:
    tuple val(meta), path("*.bam"), emit: bam
    path "versions.yml"           , emit: versions
    
    when:
    task.ext.when == null || task.ext.when
    
    script:
    def args = task.ext.args ?: ''
    def args2 = task.ext.args2 ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def samtools_command = sort_bam ? 'sort' : 'view'
    // FIXME: platform detection is wonky, just default to ILLUMINA
    def read_group = meta.read_group ?: "@RG\\tID:${meta.id}\\tSM:${meta.id}\\tPL:ILLUMINA"
    
    // tried to use -M flag but it breaks downstream tools sometimes
    // def bwa_opts = "-M"  // mark shorter split hits as secondary
    
    """
    # find the index - bwa is picky about extensions
    INDEX=`find -L ./ -name "*.amb" | sed 's/\\.amb\$//'`
    
    # sometimes bwa segfaults with too many threads on small files
    # so cap it at 8 for safety
    THREADS=\$(( $task.cpus > 8 ? 8 : $task.cpus ))
    
    bwa mem \\
        $args \\
        -t \$THREADS \\
        -R "${read_group}" \\
        \$INDEX \\
        $reads \\
        | samtools $samtools_command $args2 -@ $task.cpus -o ${prefix}.bam -
    
    # check if bam is not empty (happens sometimes with bad inputs)
    if [ ! -s ${prefix}.bam ]; then
        echo "WARNING: Output BAM is empty!"
        # exit 1  # disabled for now, breaks too many pipelines
    fi
    
    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        bwa: \$(echo \$(bwa 2>&1) | sed 's/^.*Version: //; s/Contact:.*\$//')
        samtools: \$(echo \$(samtools --version 2>&1) | sed 's/^.*samtools //; s/Using.*\$//')
    END_VERSIONS
    """
    
    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.bam
    
    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        bwa: \$(echo \$(bwa 2>&1) | sed 's/^.*Version: //; s/Contact:.*\$//')
        samtools: \$(echo \$(samtools --version 2>&1) | sed 's/^.*samtools //; s/Using.*\$//')
    END_VERSIONS
    """
}
