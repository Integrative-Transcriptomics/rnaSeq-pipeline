
def helpMessage() {
    log.info"""
    ==------------------------------------==
    Personal use RNA pipeline
    ==------------------------------------==
    Usage:
    The typical command for running the pipeline is as follows:
    nextflow run main.nf --reads  "*.fastq.gz" --reference <.fna> -profile conda

    Mandatory arguments:
      --reads                 FastQ input file containg the reads
      --reference             Input File in fasta format, nucleotide sequences. Each entry (">") is considered as one gene.
      --gtf                   Input file in gtf format, annotations

    Optional arguments:
      --M                     Count multi-mapping reads
      --O                     Count reads overlapping features
      --fraction              Fractional counts for multi-mapping/overlapping features (must be used together with -M or -O)
      --pubDir                The directory where the results will be stored [def: Results]
      --t                     The number of threads
      --cpus                  The number of CPUs
    """.stripIndent()
}

// Show help message
params.help = false
if (params.help){
    helpMessage()
    exit 0
}
params.M = false
params.O = false
params.fraction = false
if(params.fraction && !(params.O || params.M)){
  helpMessage()
  exit 0
}
params.pubDir = "Results"
pubDir = file(params.pubDir)
genome_file = file(params.reference)
gtf = file(params.gtf)

multiMapping = params.M
overlapping = params.O
fraction = params.fraction

// The basic input of the Pipeline. based on the Read name, a <base>_reference.info file is locatad, containing the information of the reference to be used for this sample
Channel.fromFilePairs(params.reads, size: 1)
        .ifEmpty { exit 1, "Readfiles not specified" }
        .into { reads_fastQC; reads_trimgalore }

/*
* FastQC
*/
process fastqc {
  tag "$id"
  label 'process_medium'
  publishDir "$pubDir/fastqc", mode: 'copy',
     saveAs: { filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename" }

  input:
    tuple id, file(reads) from reads_fastQC

  output:
    file "*_fastqc.{zip,html}" into fastqc_results

  script:
    """
      fastqc --quiet  $reads
    """
}


// 1) Trimm the reads
process trimming {
  tag "$id"
  cpus 4

  input:
    tuple id, file( read_file ) from reads_trimgalore
    publishDir "$pubDir/Trimgalore/", mode: 'copy'

  output:
    set id, file("*_trimmed.fq") into ch_trimmed
    file "*_fastqc.{zip,html}" into trimgalore_fastqc_reports
    file "*trimming_report.txt" into trimgalore_results

  script:
    """
      trim_galore --cores ${task.cpus} --dont_gzip --fastqc $read_file
    """
}

// 2) Create hisat_index
process hisat2_index {
  input:
    file reference_genome from genome_file
  output:
    file "${reference_genome.baseName}.*.ht2*" into hisat2_indeces
  script:
    """
      hisat2-build -p 2 $reference_genome ${reference_genome.baseName}.hisat2_index
    """
}

// 3) Create hisat_mapping
process hisat2_mapping {
    input:
      file indeces from hisat2_indeces.collect()
      tuple id, file(reads) from ch_trimmed
    output:
      tuple id, file("*.bam")into alignment_files
      tuple id, file("*.bam")into alignment_files_fc
      tuple id, file("*_summary.txt") into alignment_logs
    script:
      index_name = indeces[0].toString() - ~/.\d.ht2l?/
      """
      hisat2 -x $index_name \
                   -U $reads \
                   --no-spliced-alignment \
                   -p 2 \
                   --met-stderr \
                   --new-summary \
                   --dta \
                   --summary-file ${id}_summary.txt --rg-id ${id} --rg SM:${id} \
                   | samtools view -bS -F 4 -F 8 -F 256 - > ${id}.bam
      """
}

// counts features
process featureCounts {
  input:
    file annotation from gtf
    tuple id, file(bam) from alignment_files_fc
    publishDir "$pubDir/FeatureCounts/", mode: 'copy'
  output:
    tuple id, file("${id}.featureCounts.txt") into feature_counts
    tuple id, file("${id}.featureCounts.txt.summary") into featureCounts_logs
  script:
    M=""
    O=""
    frac=""
    if(multiMapping){
      M="-M"
    }
    if(overlapping){
      O="-O"
    }
    if(fraction){
      frac="--fraction"
    }
    """
    featureCounts -a $annotation -t exon -g gene_id --extraAttributes gene_name -o ${id}.featureCounts.txt $M $O $frac $bam
    """
}

// samtools sort index
process samtools {
  input:
    tag "$id"
    cpus 4
    publishDir "$pubDir/Bams/", mode: 'copy'

  input:
    tuple id, file(bam) from alignment_files

  output:
    tuple id, file ("${id}.sorted.bam*") into sorted_alignment_files

  script:
  """
    samtools sort -@ ${task.cpus} -o ${id}.sorted.bam $bam
    samtools index ${id}.sorted.bam
  """
}

// Qualimap auf Bam
process qualimap_bamqc {
  tag "$id"
  cpus 4
  publishDir "$pubDir/QualiMaps/", mode: 'copy'

  input:
    tuple id, file(bam) from sorted_alignment_files

  output:
    tuple id, file("${id}") into qualimap_results

  script:
  sorted_bam = "${id}.sorted.bam"
  """
    qualimap bamqc -nt ${task.cpus} -bam $sorted_bam -outdir ${id}
  """
}

/*
 * STEP 14 - MultiQC
 */
process multiqc {
    publishDir "${pubDir}/MultiQC", mode: 'copy'

    input:
    file (fastqc:'fastqc/*') from fastqc_results.collect().ifEmpty([])
    file ('trimgalore/*') from trimgalore_results.collect().ifEmpty([])
    file ('alignment/*') from alignment_logs.collect().ifEmpty([])
    file ('qualimap/*') from qualimap_results.collect().ifEmpty([])
    file ('featureCounts/*') from featureCounts_logs.collect().ifEmpty([])

    output:
    file "*multiqc_report.html" into multiqc_report

    script:
    """
    multiqc .\\
        -m custom_content -m picard -m preseq -m rseqc -m featureCounts -m hisat2 -m star -m cutadapt -m sortmerna -m fastqc -m qualimap -m salmon
    """
}