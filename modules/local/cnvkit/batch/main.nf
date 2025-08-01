process CNVKIT_BATCH {
    tag "$meta.id"
    label 'process_high'
    
    conda "bioconda::cnvkit=0.9.10"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/cnvkit:0.9.10--pyhdfd78af_0':
        'biocontainers/cnvkit:0.9.10--pyhdfd78af_0' }"
    
    input:
    tuple val(meta), path(tumor_bam), path(tumor_bai), path(normal_bam), path(normal_bai)
    path(reference)
    
    output:
    tuple val(meta), path("${prefix}*.cns"), emit: cnv_calls
    tuple val(meta), path("${prefix}*.cnr"), emit: cnr
    tuple val(meta), path("${prefix}*.png"), emit: plots
    path("${prefix}_metrics.txt"), emit: qc_files
    path "versions.yml", emit: versions
    
    when:
    task.ext.when == null || task.ext.when
    
    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def reference_args = params.cnvkit_reference ? "--reference ${params.cnvkit_reference}" : ""
    // had to add this check because WGS kept crashing
    def method = meta.datatype == 'wgs' ? 'wgs' : 'hybrid'
    
    // debug stuff - uncomment if cnvkit is being weird
    // def debug_flag = "--verbose"
    
    """
    # check bam size - cnvkit struggles with huge files
    BAM_SIZE=\$(stat -c%s "${tumor_bam}" 2>/dev/null || stat -f%z "${tumor_bam}")
    # echo "DEBUG: BAM size is \$BAM_SIZE bytes"
    
    # tried using --drop-low-coverage but it removed too much
    # also tried --no-gc but results were worse
    
    # Run CNVkit 
    cnvkit.py batch \\
        ${tumor_bam} \\
        --normal ${normal_bam} \\
        --fasta ${reference} \\
        --output-reference ${prefix}_reference.cnn \\
        --output-dir . \\
        --method ${method} \\
        --scatter \\
        --diagram \\
        -p ${task.cpus} \\
        ${args}
    
    # rename outputs - cnvkit names are confusing
    for file in *.cn{s,r}; do
        if [[ -f "\$file" ]] && [[ ! "\$file" =~ ^${prefix} ]]; then
            mv "\$file" "${prefix}_\$file"
        fi
    done
    
    # scatter plot - sometimes fails with matplotlib errors
    cnvkit.py scatter ${prefix}*.cnr -s ${prefix}*.cns -o ${prefix}_scatter.png || touch ${prefix}_scatter.png
    
    # metrics
    echo "Sample: ${meta.id}" > ${prefix}_metrics.txt
    echo "Method: ${method}" >> ${prefix}_metrics.txt
    # this crashes sometimes, not sure why
    cnvkit.py metrics ${prefix}*.cnr -s ${prefix}*.cns >> ${prefix}_metrics.txt || echo "Metrics failed" >> ${prefix}_metrics.txt
    
    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        cnvkit: \$(cnvkit.py version 2>&1 | sed 's/cnvkit v//')
    END_VERSIONS
    """
    
    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.cns
    touch ${prefix}.cnr
    touch ${prefix}_scatter.png
    touch ${prefix}_metrics.txt
    
    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        cnvkit: \$(cnvkit.py version 2>&1 | sed 's/cnvkit v//')
    END_VERSIONS
    """
}
