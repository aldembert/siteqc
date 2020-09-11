#!/usr/bin/env nextflow
/*
========================================================================================
                         siteqc
========================================================================================
siteqc Analysis Pipeline.
#### Homepage / Documentation
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    // TODO : Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run  lifebit-ai/siteqc --input .. -profile docker

    Mandatory arguments:
      --input [file]                  Path to input sample sheet csv of bcf files.
                                      The name of the files must be consistent across files.
                                      see example:
                                      test_all_chunks_merged_norm_chr10_53607810_55447336.bcf.gz
                                      {name}_{CHR}_{START_POS}_{END_POS}.bcf.gz
                                      Consistency is important here as a variable ('region')
                                      is extracted from the filename.

      -profile [str]                  Configuration profile to use. Can use multiple (comma separated)
                                      Available: conda, docker, singularity, test, awsbatch, <institute> and more


    Options:
      --query_format_start [str]      Bcftools query format used for creating the skeleton of the sites.
      --query_format_miss1 [str]      Bcftools query format used for the missingeness 1 step.
    
    References                        If not specified in the configuration file or you wish to overwrite any of the references
      --fasta [file]                  Path to fasta reference

    Other options:
      --outdir [file]                 The output directory where the results will be saved
      --publish_dir_mode [str]        Mode for publishing results in the output directory. Available: symlink, rellink, link, copy, copyNoFollow, move (Default: copy)
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful
      --max_multiqc_email_size [str]  Threshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic

    AWSBatch options:
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion [str]               The AWS Region for your AWS Batch job to run on
      --awscli [str]                  Path to the AWS CLI tool
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Has the run name been specified by the user?
// this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

// Check AWS batch settings
if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Define variables
query_format_start = params.query_format_start
query_format_miss1 = params.query_format_miss1

// Input list .csv file of tissues to analyse
// [chr10_52955340_55447336, test_all_chunks_merged_norm_chr10_52955340_55447336.bcf.gz, test_all_chunks_merged_norm_chr10_52955340_55447336.bcf.gz.csi]

// Define channels based on params
  Channel.fromPath(params.inputDir+'/*.txt')
                        .ifEmpty { exit 1, "Input dir for annotation txt files not found at ${params.inputDir}. Is the dir path correct?" }
                        .map { txt -> ['chr'+ txt.simpleName.split('_chr').last() , txt] }
                        .set { ch_bcftools_site_metrics_subcols }

  Channel.fromPath(params.inputFinalPlatekeys)
                        .ifEmpty { exit 1, "Input file with samples and platekeys data not found at ${params.inputFinalPlatekeys}. Is the file path correct?" }
                        .set { ch_inputFinalPlatekeys }

  Channel.fromPath(params.inputMichiganLDfile)
                        .ifEmpty { exit 1, "Input file with Michigan LD data not found at ${params.inputMichiganLDfile}. Is the file path correct?" }
                        .set { ch_inputMichiganLDfile }
  Channel.fromPath(params.inputPCsancestryrelated)
                        .ifEmpty { exit 1, "Input file with Michigan LD data not found at ${params.inputPCsancestryrelated}. Is the file path correct?" }
                        .set { ch_inputPCsancestryrelated }

  Channel.fromPath(params.inputAncestryAssignmentProbs)
                        .ifEmpty { exit 1, "Input file with Michigan LD data not found at ${params.inputAncestryAssignmentProbs}. Is the file path correct?" }
                        .set { ch_inputAncestryAssignmentProbs }
                        
                        
  Channel.fromPath(params.inputMichiganLDfileExclude)
                        .ifEmpty { exit 1, "Input file with Michigan LD for excluding regions  not found at ${params.inputMichiganLDfile}. Is the file path correct?" }
                        .set { ch_inputMichiganLDfileExclude }
if (params.input.endsWith(".csv")) {

  Channel.fromPath(params.input)
                        .ifEmpty { exit 1, "Input .csv list of input tissues not found at ${params.input}. Is the file path correct?" }
                        .splitCsv(sep: ',',  skip: 1)
                        .map { bcf, index -> ['chr'+file(bcf).simpleName.split('_chr').last() , file(bcf), file(index)] }
                        .set { ch_bcfs }

}


// Plink files for mend_err_p* processes


// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
// TODO nf-core: Report custom parameters here
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Profile Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Profile Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config Profile URL']         = params.config_profile_url
summary['Config Files'] = workflow.configFiles.join(', ')
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"




 /* STEP_17
 * STEP - sort_compress: Sort and compress site metric data for KING step
 */
process sort_compress {
    publishDir "${params.outdir}/bcftools_site_metrics_subcols/", mode: params.publish_dir_mode

    input:
    set val(region), file(bcftools_site_metrics_subcols) from ch_bcftools_site_metrics_subcols


    output:
    set val(region),file ("BCFtools_site_metrics_SUBCOLS${region}_sorted.txt.gz"), file("BCFtools_site_metrics_SUBCOLS${region}_sorted.txt.gz.tbi") into ch_sort_compress
    
    script:

    """
    sort -k2 -n ${bcftools_site_metrics_subcols} > BCFtools_site_metrics_SUBCOLS${region}_sorted.txt
    bgzip -f BCFtools_site_metrics_SUBCOLS${region}_sorted.txt && \
    tabix -s1 -b2 -e2 BCFtools_site_metrics_SUBCOLS${region}_sorted.txt.gz
    """
}
//  KING WORKFLOW

/* STEP_18
 * STEP - filter_regions: Produce BCFs of our data filtered to sites pass sites
 */
process filter_regions {
    publishDir "${params.outdir}/regionsFiltered/", mode: params.publish_dir_mode

    input:
    set val(region), file(bcf), file(index) from ch_bcfs
    set val(region2),file ("BCFtools_site_metrics_SUBCOLS${region}_sorted.txt.gz"), file("BCFtools_site_metrics_SUBCOLS${region}_sorted.txt.gz.tbi") from ch_sort_compress
    

    output:
    set val(region), file ("${region}_regionsFiltered.bcf") into ch_regions_filtered

    script:
    """
    bcftools view ${bcf} \
    -T BCFtools_site_metrics_SUBCOLS${region}_sorted.txt.gz  \
    -Ob \
    -o ${region}_regionsFiltered.bcf
    """
}


process further_filtering {
    publishDir "${params.outdir}/further_filtering/", mode: params.publish_dir_mode

    input:
    set val(region), file(bcf_filtered) from ch_regions_filtered
    file (michiganld_exclude_regions_file) from ch_inputMichiganLDfile
    output:
    set val(region), file("MichiganLD_regionsFiltered_${region}.bcf"), file("MAF_filtered_1kp3intersect_${region}.txt") into ch_further_filtering

    script:
    """
    bcftools view ${bcf_filtered} \
    -i 'INFO/OLD_MULTIALLELIC="." & INFO/OLD_CLUMPED="."' \
    -v snps  | \
    bcftools annotate \
    --set-id '%CHROM:%POS-%REF/%ALT-%INFO/OLD_CLUMPED-%INFO/OLD_MULTIALLELIC' | \
    bcftools +fill-tags -Ob \
    -o MichiganLD_regionsFiltered_${region}.bcf \
    -- -t MAF
    #Produce filtered txt file
    bcftools query MichiganLD_regionsFiltered_${region}.bcf \
    -i 'MAF[0]>0.01' -f '%CHROM\t%POS\t%REF\t%ALT\t%MAF\n' | \
    awk -F "\t" '{ if((\$3 == "G" && \$4 == "C") || (\$3 == "A" && \$4 == "T")) {next} { print \$0} }' \
    > MAF_filtered_1kp3intersect_${region}.txt
    """
}

// /* STEP_20
//  * STEP - create_final_king_vcf: Produce new BCF just with filtered sites
//  */
process create_final_king_vcf {
    publishDir "${params.outdir}/create_final_king_vcf/", mode: params.publish_dir_mode

    input:
    set val(region), file("MichiganLD_regionsFiltered_${region}.bcf"), file("MAF_filtered_1kp3intersect_${region}.txt") from ch_further_filtering
    file agg_samples_txt from ch_inputFinalPlatekeys
    
    output:
    set val(region), file("${region}_filtered.vcf.gz"), file("${region}_filtered.vcf.gz.tbi") into ch_create_final_king_vcf
    file "${region}_filtered.vcf.gz" into ch_vcfs_create_final_king_vcf
    file "${region}_filtered.vcf.gz.tbi" into ch_tbi_create_final_king_vcf
    script:
    """
    #Now filter down our file to just samples we want in our GRM. This removes any withdrawals that we learned of during the process of aggregation
    #Store the header
    bcftools view \
    -S ${agg_samples_txt} \
    --force-samples \
    -h MichiganLD_regionsFiltered_${region}.bcf \
    > ${region}_filtered.vcf
    
    #Then match against all variant cols in our subsetted bcf to our maf filtered, intersected sites and only print those that are in the variant file.
    #Then append this to the stored header, SNPRelate needs vcfs so leave as is
    bcftools view \
    -H MichiganLD_regionsFiltered_${region}.bcf \
    -S ${agg_samples_txt} \
    --force-samples \
    | awk -F '\t' 'NR==FNR{c[\$1\$2\$3\$4]++;next}; c[\$1\$2\$4\$5] > 0' MAF_filtered_1kp3intersect_${region}.txt - >> ${region}_filtered.vcf
    bgzip ${region}_filtered.vcf
    tabix ${region}_filtered.vcf.gz
    """
}

/* STEP_21
 * STEP - concat_king_vcf: Concatenate compressed vcfs to per chromosome files
 */
chrs = [10]
//chrs = [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,10,21,22]
process concat_king_vcf {
    publishDir "${params.outdir}/concat_king_vcf/", mode: params.publish_dir_mode

    input:
    set val(region), file("${region}_filtered.vcf.gz"), file("${region}_filtered.vcf.gz.tbi") from ch_create_final_king_vcf
    file "*.vcf.gz" from ch_vcfs_create_final_king_vcf.collect()
    file "*.tbi" from ch_tbi_create_final_king_vcf.collect()
    each chr from chrs
    output:
    set val(chr),file("chrom${chr}_merged_filtered.vcf.gz"),file("chrom${chr}_merged_filtered.vcf.gz.tbi") into ch_vcfs_per_chromosome

    script:
    """
    find -L . -type f -name chr${chr}_*.vcf.gz > tmp.files_chrom${chr}.txt
    bcftools concat \
    -f tmp.files_chrom${chr}.txt \
    -Oz \
    -o chrom${chr}_merged_filtered.vcf.gz && \
    tabix chrom${chr}_merged_filtered.vcf.gz && \
    rm tmp.files_chrom${chr}.txt
    """
}

// /* STEP_22
//  * STEP - make_bed_all: Make BED files for 1000KGP3 intersected vcfs
//  */

process make_bed_all {
    publishDir "${params.outdir}/make_bed_all/", mode: params.publish_dir_mode

    input:
    set val(chr),file("chrom${chr}_merged_filtered.vcf.gz"),file("chrom${chr}_merged_filtered.vcf.gz.tbi") from ch_vcfs_per_chromosome
    
    output:
    set val(chr),file("BED_${chr}.bed"),file("BED_${chr}.bim"),file("BED_${chr}.fam") into ch_make_bed_all

    script:

    """
    bcftools view chrom${chr}_merged_filtered.vcf.gz \
    -Ov |\
    plink --vcf /dev/stdin \
    --vcf-half-call m \
    --double-id \
    --make-bed \
    --real-ref-alleles \
    --allow-extra-chr \
    --out BED_${chr}
    """
}
/* STEP_23
 * STEP - ld_bed: LD prune SNPs
 */

 process ld_bed {
    publishDir "${params.outdir}/ld_bed/", mode: params.publish_dir_mode

    input:
    set val(chr),file("BED_${chr}.bed"),file("BED_${chr}.bim"),file("BED_${chr}.fam") from ch_make_bed_all
    file(michiganld_exclude_regions_file) from ch_inputMichiganLDfileExclude
    output:
    file "BED_LDpruned_${chr}*" into ch_ld_bed

    script:
    """
    #Not considering founders in this as all of our SNPs are common
    plink  \
    --exclude range ${michiganld_exclude_regions_file} \
    --keep-allele-order \
    --bfile BED_${chr} \
    --indep-pairwise 500kb 1 0.1 \
    --out BED_LD_${chr}
    
    #Now that we have our correct list of SNPs (prune.in), filter the original
    #bed file to just these sites
    plink \
    --make-bed \
    --bfile BED_${chr} \
    --keep-allele-order \
    --extract BED_LD_${chr}.prune.in \
    --double-id \
    --allow-extra-chr \
    --out BED_LDpruned_${chr}
    """
}

/* STEP_24
 * STEP - merge_autosomes: Merge autosomes to genome wide BED files
 */

process merge_autosomes {
    publishDir "${params.outdir}/merge_autosomes/", mode: params.publish_dir_mode

    input:
    file chr_ld_pruned_bed from ch_ld_bed.collect()

    output:
    set file("autosomes_LD_pruned_1kgp3Intersect.bed"), file("autosomes_LD_pruned_1kgp3Intersect.bim"), file("autosomes_LD_pruned_1kgp3Intersect.fam"),file("autosomes_LD_pruned_1kgp3Intersect.nosex") into (ch_merge_autosomes , ch_merge_autosomes2, ch_merge_autosomes3, ch_merge_autosomes4)

    script:
    """
    for i in {1..22}; do if [ -f "BED_LDpruned_\$i.bed" ]; then echo BED_LDpruned_\$i >> mergelist.txt; fi ;done
    plink --merge-list mergelist.txt \
    --make-bed \
    --out autosomes_LD_pruned_1kgp3Intersect
    rm mergelist.txt
    """
}

/* STEP_25
 * STEP - hwe_pruning_30k_data: Produce a first pass HWE filter
 * We use:
 * The 195k SNPs from above
 * The intersection bfiles (on all 80k)
 * Then we make BED files of unrelated individuals for each superpop (using only unrelated samples from 30k)
 * We do this using the inferred ancestries from the 30k
 */

// TODO: consider decoupling R scripts from plink scripts
process hwe_pruning_30k_data {
    publishDir "${params.outdir}/hwe_pruning_30k_data/", mode: params.publish_dir_mode

    input:
    set file("autosomes_LD_pruned_1kgp3Intersect.bed"), file("autosomes_LD_pruned_1kgp3Intersect.bim"), file("autosomes_LD_pruned_1kgp3Intersect.fam"),file("autosomes_LD_pruned_1kgp3Intersect.nosex") from ch_merge_autosomes
    file (ancestry_assignment_probs) from ch_inputAncestryAssignmentProbs
    file (pc_sancestry_related) from ch_inputPCsancestryrelated
    output:
    
    set file("hwe10e-2_superpops_195ksnps"), file("hwe10e-6_superpops_195ksnps") into ch_hwe_pruning_30k_data
    
    script:
    """
    R -e 'library(data.table); 
    print("Hola0");
    library(dplyr);
    print("Hola1"); 
    dat <- fread("${ancestry_assignment_probs}") %>% as_tibble();
    print("Hola2");
    unrels <- fread("${pc_sancestry_related}") %>% as_tibble() %>% filter(unrelated_set == 1);
    dat <- dat %>% filter(plate_key %in% unrels\$plate_key);
    for(col in c("AFR","EUR","SAS","EAS")){dat[dat[col]>0.8,c("plate_key",col)] %>% write.table(paste0(col,"pop.txt"), quote = F, row.names=F)}
    '
    
    bedmain="autosomes_LD_pruned_1kgp3Intersect"
    for pop in AFR EUR SAS EAS; do
        echo \${pop}
        awk '{print \$1"\t"\$1}' \${pop}pop.txt > \${pop}keep
        plink \
        --make-bed \
        --bfile \${bedmain} \
        --out \${pop} 
        
        plink --bfile \${pop} --hardy --out \${pop} --nonfounders
    done

    R -e 'library(data.table);
    library(dplyr);
    dat <- lapply(c("EUR.hwe","AFR.hwe", "SAS.hwe", "EAS.hwe"),fread);
    names(dat) <- c("EUR.hwe","AFR.hwe", "SAS.hwe", "EAS.hwe");
    dat <- dat %>% bind_rows(.id="id");
    write.table(dat, "combinedHWE.txt", row.names = F, quote = F)
    '
    R -e 'library(dplyr); library(data.table);
        dat <- fread("combinedHWE.txt") %>% as_tibble();
        #Create set that is just SNPS that are >10e-6 in all pops
        dat %>% filter(P >10e-6) %>% group_by(SNP) %>% count() %>% filter(n==4) %>% select(SNP) %>% distinct() %>%
        write.table("hwe10e-6_superpops_195ksnps", row.names = F, quote = F)
        '
    R -e 'library(dplyr); library(data.table);
        dat <- fread("combinedHWE.txt") %>% as_tibble();
        #Create set that is just SNPS that are >10e-2 in all pops
        dat %>% filter(P >10e-2) %>% group_by(SNP) %>% count() %>% filter(n==4) %>% select(SNP) %>% distinct() %>%
        write.table("hwe10e-2_superpops_195ksnps", row.names = F, quote = F)
        '

    """
}

process get_king_coeffs {
    publishDir "${params.outdir}/get_king_coeffs/", mode: params.publish_dir_mode
    container = "lifebitai/plink2"
    input:
    set file("autosomes_LD_pruned_1kgp3Intersect.bed"), file("autosomes_LD_pruned_1kgp3Intersect.bim"), file("autosomes_LD_pruned_1kgp3Intersect.fam"),file("autosomes_LD_pruned_1kgp3Intersect.nosex") from ch_merge_autosomes2

    output:
    file "matrix-autosomes_LD_pruned_1kgp3Intersect*" into ch_get_king_coeffs

    script:

    """
    plink2 --bfile \
    autosomes_LD_pruned_1kgp3Intersect \
    --make-king square \
    --out \
    matrix-autosomes_LD_pruned_1kgp3Intersect \
    --thread-num 30
    """
}

/* STEP_27
 * STEP - get_king_coeffs_alt
 * Daniel's notes:
 * The main difference for this is that we are aiming to do all the pcAIR
 * using other tools. Therefore the output needs to be different
 */

process get_king_coeffs_alt {
    publishDir "${params.outdir}/get_king_coeffs_alt/", mode: params.publish_dir_mode
    container = "lifebitai/plink2"
    input:
    set file("autosomes_LD_pruned_1kgp3Intersect.bed"), file("autosomes_LD_pruned_1kgp3Intersect.bim"), file("autosomes_LD_pruned_1kgp3Intersect.fam"),file("autosomes_LD_pruned_1kgp3Intersect.nosex") from ch_merge_autosomes3
    set file("hwe10e-2_superpops_195ksnps"), file("hwe10e-6_superpops_195ksnps") from ch_hwe_pruning_30k_data

    output:
    set file("autosomes_LD_pruned_1kgp3Intersect_triangle.king.bin"),file("autosomes_LD_pruned_1kgp3Intersect_triangle.king.id"), file("autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_2.king.bin"),file("autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_2.king.id"),file("autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_6.king.bin"), file("autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_6.king.id") into ch_get_king_coeffs_alt

    script:

    """
    plink2 --bfile \
    autosomes_LD_pruned_1kgp3Intersect \
    --make-king triangle bin \
    --out \
    autosomes_LD_pruned_1kgp3Intersect_triangle \
    --thread-num 30
    plink2 --bfile autosomes_LD_pruned_1kgp3Intersect --extract hwe10e-2_superpops_195ksnps --make-king triangle bin --out autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_2
    plink2 --bfile autosomes_LD_pruned_1kgp3Intersect --extract hwe10e-6_superpops_195ksnps --make-king triangle bin --out autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_6
    """
}

/* STEP_28
 * STEP - pcair_alternate: 
 * Daniel's notes:
 * This isn't actually intended to run as a function, it is just to stop stuff running
 * when sourcing this file that we wrap it in a function
 * Alternate approach to producing the PC-relate info
 */

process pcair_alternate {
    publishDir "${params.outdir}/pcair_alternate/", mode: params.publish_dir_mode
    container = "lifebitai/plink2"
    input:
    set file("autosomes_LD_pruned_1kgp3Intersect.bed"), file("autosomes_LD_pruned_1kgp3Intersect.bim"), file("autosomes_LD_pruned_1kgp3Intersect.fam"),file("autosomes_LD_pruned_1kgp3Intersect.nosex") from ch_merge_autosomes4
    set file("autosomes_LD_pruned_1kgp3Intersect_triangle.king.bin"),file("autosomes_LD_pruned_1kgp3Intersect_triangle.king.id"), file("autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_2.king.bin"),file("autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_2.king.id"),file("autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_6.king.bin"), file("autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_6.king.id") from ch_get_king_coeffs_alt

    output:
    set file("autosomes_LD_pruned_1kgp3Intersect_unrelated*"), file("autosomes_LD_pruned_1kgp3Intersect_related*") into ch_pcair_alternate
    set file("autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_2.king.cutoff.in.id"), file("autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_6.king.cutoff.in.id"),file("autosomes_LD_pruned_1kgp3Intersect.king.cutoff.in.id") into ch_pcair_alternate_cutoffs
    script:

    """
    plink2 --bfile autosomes_LD_pruned_1kgp3Intersect \
    --king-cutoff autosomes_LD_pruned_1kgp3Intersect_triangle 0.0442 && \
    mv plink2.king.cutoff.in.id autosomes_LD_pruned_1kgp3Intersect.king.cutoff.in.id && \
    mv plink2.king.cutoff.out.id autosomes_LD_pruned_1kgp3Intersect.king.cutoff.out.id



    plink2 --bfile autosomes_LD_pruned_1kgp3Intersect \
    --king-cutoff autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_2 0.0442 && \
    mv plink2.king.cutoff.in.id  autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_2.king.cutoff.in.id && \
    mv plink2.king.cutoff.out.id  autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_2.king.cutoff.out.id
    plink2 --bfile autosomes_LD_pruned_1kgp3Intersect \
    --king-cutoff autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_6 0.0442 && \
    cp plink2.king.cutoff.in.id  autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_6.king.cutoff.in.id && \
    cp plink2.king.cutoff.out.id  autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_6.king.cutoff.out.id



    plink2 --bfile autosomes_LD_pruned_1kgp3Intersect \
    --make-bed \
    --keep plink2.king.cutoff.in.id \
    --out autosomes_LD_pruned_1kgp3Intersect_unrelated


    plink2 --bfile autosomes_LD_pruned_1kgp3Intersect \
    --make-bed \
    --remove plink2.king.cutoff.in.id \
    --out autosomes_LD_pruned_1kgp3Intersect_related
    """
 }

 /* STEP_28-a
 * STEP - pcair_alternate-Rscript-complement: 
 */
process pcair_alternate_Rscript {
    publishDir "${params.outdir}/pcair_alternate_Rscript/", mode: params.publish_dir_mode
    echo true
    input:
    set file("autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_2.king.cutoff.in.id"), file("autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_6.king.cutoff.in.id"),file("autosomes_LD_pruned_1kgp3Intersect.king.cutoff.in.id") from ch_pcair_alternate_cutoffs
    
    output:

    script:
    """
        R -e 'library(data.table); library(dplyr); 
        dat <- fread("autosomes_LD_pruned_1kgp3Intersect.king.cutoff.in.id") %>% as_tibble();
        hwe2 <- fread("autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_2.king.cutoff.in.id") %>% as_tibble();
        hwe6 <- fread("autosomes_LD_pruned_1kgp3Intersect_triangle_HWE10_6.king.cutoff.in.id") %>% as_tibble();
        dat <- bind_rows(dat, hwe2, hwe6, .id="id");
        dat %>% group_by(id) %>% summarise(n()); 
        dat %>% group_by(IID) %>% summarise(n=n()) %>% count(n)'

    """
}
 


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
