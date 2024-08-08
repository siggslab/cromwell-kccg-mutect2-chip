version 1.0

# =================================================================================== #
# m2.wdl                                                                              #
#                                                                                     #
# This workflow has been adapted from the mutect2.wdl workflow developed by the Broad #
# Institue. The base version of the original workflow can be found here:              #
# https://github.com/broadinstitute/gatk/blob/4.1.6.0/scripts/mutect2_wdl/mutect2.wdl #
#                                                                                     #
# The CramToBam and Funcotator tasks have been removed and a few minor alterations    #
# have been made for integration into the larger CHIP workflow.                       #
#                                                                                     #
# This pipeline has been developed for use by the Kinghorn                            #
# Centre for Clinical Genomics and the Garvan Institute for                           # 
# Medical Research.                                                                   #
#                                                                                     #
# Author: Michael Geaghan (micgea)                                                    #
# Created: 2023/04/04                                                                 #
# =================================================================================== #

# ========== Mutect2 ========== #
## Copyright Broad Institute, 2017
##
## This WDL workflow runs GATK4 Mutect 2 on a single tumor-normal pair or on a single tumor sample,
## and performs additional filtering tasks.
##
## Main requirements/expectations :
## - One analysis-ready BAM file (and its index) for each sample
##
## Description of inputs:
##
## ** Runtime **
## gatk_docker: docker image to use for GATK 4 Mutect2
## preemptible: how many preemptions to tolerate before switching to a non-preemptible machine (on Google)
## max_retries: how many times to retry failed tasks -- very important on the cloud when there are transient errors
## gatk_override: (optional) local file or Google bucket path to a GATK 4 java jar file to be used instead of the GATK 4 jar
##                in the docker image.  This must be supplied when running in an environment that does not support docker
##                (e.g. SGE cluster on a Broad on-prem VM)
##
## ** Workflow options **
## intervals: genomic intervals (will be used for scatter)
## scatter_count: number of parallel jobs to generate when scattering over intervals
## m2_extra_args, m2_extra_filtering_args: additional arguments for Mutect2 calling and filtering (optional)
## split_intervals_extra_args: additional arguments for splitting intervals before scattering (optional)
## run_orientation_bias_mixture_model_filter: (optional) if true, filter orientation bias sites with the read orientation artifact mixture model.
##
## ** Primary inputs **
## ref_fasta, ref_fai, ref_dict: reference genome, index, and dictionary
## tumor_bam, tumor_bam_index: BAM and index for the tumor sample
## normal_bam, normal_bam_index: BAM and index for the normal sample
##
## ** Primary resources ** (optional but strongly recommended)
## pon, pon_idx: optional panel of normals (and its index) in VCF format containing probable technical artifacts (false positves)
## gnomad, gnomad_idx: optional database of known germline variants (and its index) (see http://gnomad.broadinstitute.org/downloads)
## variants_for_contamination, variants_for_contamination_idx: VCF of common variants (and its index)with allele frequencies for calculating contamination
##
## ** Secondary resources ** (for optional tasks)
## realignment_index_bundle: resource for FilterAlignmentArtifacts, which runs if and only if it is specified.  Generated by BwaMemIndexImageCreator.
##
## Outputs :
## - One VCF file and its index with primary filtering applied; a bamout.bam
##   file of reassembled reads if requested
##
## Cromwell version support
## - Successfully tested on v34
##
## LICENSING :
## This script is released under the WDL source code license (BSD-3) (see LICENSE in
## https://github.com/broadinstitute/wdl). Note however that the programs it calls may
## be subject to different licenses. Users are responsible for checking that they are
## authorized to run all programs before running this script. Please see the docker
## pages at https://hub.docker.com/r/broadinstitute/* for detailed licensing information
## pertaining to the included programs.

struct Runtime {
    String gatk_docker
    File? gatk_override
    Int max_retries
    Int preemptible
    Int cpu
    Int machine_mem
    Int command_mem
    Int disk
    Int boot_disk_size
}

workflow Mutect2 {
    input {
        # Mutect2 inputs
        File? intervals
        File ref_fasta
        File ref_fai
        File ref_dict
        File tumor_reads
        File tumor_reads_index
        File? normal_reads
        File? normal_reads_index
        File? pon
        File? pon_idx
        Int scatter_count = 10
        File? gnomad
        File? gnomad_idx
        File? variants_for_contamination
        File? variants_for_contamination_idx
        File? realignment_index_bundle
        String? realignment_extra_args
        Boolean? run_orientation_bias_mixture_model_filter
        String? m2_extra_args
        String? m2_extra_filtering_args
        String? split_intervals_extra_args
        Boolean? make_bamout
        Boolean? compress_vcfs
        File? gga_vcf
        File? gga_vcf_idx
        
        # Runtime options
        String gatk_docker = "australia-southeast1-docker.pkg.dev/pb-dev-312200/somvar-images/gatk@sha256:0359ae4f32f2f541ca86a8cd30ef730bbaf8c306b9d53d2d520262d3e84b3b2b"  # :4.2.1.0
        File? gatk_override
        Int? preemptible
        Int? max_retries
        Int small_task_cpu = 4
        Int small_task_mem = 4000
        Int small_task_disk = 100
        Int command_mem_padding = 1000
        Int boot_disk_size = 12
        Int m2_mem = 5000
        Int m2_cpu = 4
        Int learn_read_orientation_mem = 5000
        Int filter_alignment_artifacts_mem = 5000

        # Use as a last resort to increase the disk given to every task in case of ill behaving data
        Int? emergency_extra_disk

        # These are multipliers to multipler inputs by to make sure we have enough disk to accommodate for possible output sizes
        # Large is for Bams/WGS vcfs
        # Small is for metrics/other vcfs
        Float large_input_to_output_multiplier = 2.25
        Float small_input_to_output_multiplier = 2.0
    }

    Int preemptible_or_default = select_first([preemptible, 2])
    Int max_retries_or_default = select_first([max_retries, 2])

    Boolean compress = select_first([compress_vcfs, false])
    Boolean run_ob_filter = select_first([run_orientation_bias_mixture_model_filter, false])
    Boolean make_bamout_or_default = select_first([make_bamout, false])

    # Disk sizes used for dynamic sizing
    Int ref_size = ceil(size(ref_fasta, "GB") + size(ref_dict, "GB") + size(ref_fai, "GB"))
    Int tumor_reads_size = ceil(size(tumor_reads, "GB") + size(tumor_reads_index, "GB"))
    Int gnomad_vcf_size = if defined(gnomad) then ceil(size(gnomad, "GB")) else 0
    Int normal_reads_size = if defined(normal_reads) then ceil(size(normal_reads, "GB") + size(normal_reads_index, "GB")) else 0

    # If no tar is provided, the task downloads one from broads ftp server
    Int gatk_override_size = if defined(gatk_override) then ceil(size(gatk_override, "GB")) else 0

    # This is added to every task as padding, should increase if systematically you need more disk for every call
    Int disk_pad = 10 + gatk_override_size + select_first([emergency_extra_disk,0])

    # logic about output file names -- these are the names *without* .vcf extensions
    String output_basename = basename(basename(tumor_reads, ".bam"),".cram")  #hacky way to strip either .bam or .cram
    String unfiltered_name = output_basename + "-unfiltered"
    String filtered_name = output_basename + "-filtered"
    String output_vcf_name = output_basename + ".vcf"

    Int small_task_cpu_mult = if small_task_cpu > 1 then small_task_cpu - 1 else 1
    Int cmd_mem = small_task_mem - command_mem_padding

    Runtime standard_runtime = {
        "gatk_docker": gatk_docker,
        "gatk_override": gatk_override,
        "max_retries": max_retries_or_default,
        "preemptible": preemptible_or_default,
        "cpu": small_task_cpu,
        "machine_mem": small_task_mem,
        "command_mem": cmd_mem,
        "disk": small_task_disk + disk_pad,
        "boot_disk_size": boot_disk_size
    }

    File tumor_bam = tumor_reads
    File tumor_bai = tumor_reads_index
    Int tumor_bam_size = ceil(size(tumor_bam, "GB") + size(tumor_bai, "GB"))

    File? normal_bam = normal_reads
    File? normal_bai = normal_reads_index
    Int normal_bam_size = if defined(normal_bam) then ceil(size(normal_bam, "GB") + size(normal_bai, "GB")) else 0

    Int m2_output_size = tumor_bam_size / scatter_count
    #TODO: do we need to change this disk size now that NIO is always going to happen (for the google backend only)
    Int m2_per_scatter_size = (tumor_bam_size + normal_bam_size) + ref_size + gnomad_vcf_size + m2_output_size + disk_pad

    call SplitIntervals {
        input:
            intervals = intervals,
            ref_fasta = ref_fasta,
            ref_fai = ref_fai,
            ref_dict = ref_dict,
            scatter_count = scatter_count,
            split_intervals_extra_args = split_intervals_extra_args,
            runtime_params = standard_runtime
    }

    scatter (subintervals in SplitIntervals.interval_files ) {
        call M2 {
            input:
                intervals = subintervals,
                ref_fasta = ref_fasta,
                ref_fai = ref_fai,
                ref_dict = ref_dict,
                tumor_bam = tumor_bam,
                tumor_bai = tumor_bai,
                normal_bam = normal_bam,
                normal_bai = normal_bai,
                pon = pon,
                pon_idx = pon_idx,
                gnomad = gnomad,
                gnomad_idx = gnomad_idx,
                preemptible = preemptible,
                max_retries = max_retries,
                m2_extra_args = m2_extra_args,
                variants_for_contamination = variants_for_contamination,
                variants_for_contamination_idx = variants_for_contamination_idx,
                make_bamout = make_bamout_or_default,
                run_ob_filter = run_ob_filter,
                compress = compress,
                gga_vcf = gga_vcf,
                gga_vcf_idx = gga_vcf_idx,
                gatk_override = gatk_override,
                gatk_docker = gatk_docker,
                disk_space = m2_per_scatter_size,
                mem_mb = m2_mem,
                mem_pad = command_mem_padding,
                cpu = m2_cpu
        }
    }

    Array[File] m2_tumor_pileups = select_all(M2.tumor_pileups)
    Array[File] m2_normal_pileups = select_all(M2.normal_pileups)

    Int merged_vcf_size = ceil(size(M2.unfiltered_vcf, "GB"))
    Int merged_bamout_size = ceil(size(M2.output_bamOut, "GB"))

    if (run_ob_filter) {
        call LearnReadOrientationModel {
            input:
                f1r2_tar_gz = M2.f1r2_counts,
                runtime_params = standard_runtime,
                output_name = output_basename,
                mem_mb = learn_read_orientation_mem,
                mem_pad = command_mem_padding
        }
    }

    call MergeVCFs {
        input:
            input_vcfs = M2.unfiltered_vcf,
            input_vcf_indices = M2.unfiltered_vcf_idx,
            output_name = unfiltered_name,
            compress = compress,
            runtime_params = standard_runtime
    }

    if (make_bamout_or_default) {
        call MergeBamOuts {
            input:
                ref_fasta = ref_fasta,
                ref_fai = ref_fai,
                ref_dict = ref_dict,
                bam_outs = M2.output_bamOut,
                output_vcf_name = basename(MergeVCFs.merged_vcf, ".vcf"),
                runtime_params = standard_runtime,
                disk_space = ceil(merged_bamout_size * large_input_to_output_multiplier) + disk_pad,
        }
    }

    call MergeStats {
        input:
            stats = M2.stats,
            output_name = output_basename,
            runtime_params = standard_runtime
    }

    if (defined(variants_for_contamination)) {
        call MergePileupSummaries as MergeTumorPileups {
            input:
                input_tables = m2_tumor_pileups,
                output_name = output_basename,
                ref_dict = ref_dict,
                runtime_params = standard_runtime
        }

        if (defined(normal_bam)){
            call MergePileupSummaries as MergeNormalPileups {
                input:
                    input_tables = m2_normal_pileups,
                    output_name = output_basename,
                    ref_dict = ref_dict,
                    runtime_params = standard_runtime
            }
        }

        call CalculateContamination {
            input:
                tumor_pileups = MergeTumorPileups.merged_table,
                normal_pileups = MergeNormalPileups.merged_table,
                output_name = output_basename,
                runtime_params = standard_runtime
        }
    }

    call Filter {
        input:
            ref_fasta = ref_fasta,
            ref_fai = ref_fai,
            ref_dict = ref_dict,
            intervals = intervals,
            unfiltered_vcf = MergeVCFs.merged_vcf,
            unfiltered_vcf_idx = MergeVCFs.merged_vcf_idx,
            output_name = filtered_name,
            compress = compress,
            mutect_stats = MergeStats.merged_stats,
            contamination_table = CalculateContamination.contamination_table,
            maf_segments = CalculateContamination.maf_segments,
            artifact_priors_tar_gz = LearnReadOrientationModel.artifact_prior_table,
            m2_extra_filtering_args = m2_extra_filtering_args,
            runtime_params = standard_runtime,
            disk_space = ceil(size(MergeVCFs.merged_vcf, "GB") * small_input_to_output_multiplier) + disk_pad
    }

    # FilterAlignmentArtifacts is experimental and not recommended for production use
    # There is also a bug causing issues when running on the Garvan HPC
    # This may be an issue with the underlying C library, and may be hardware-specific, as the error is similar to https://gatk.broadinstitute.org/hc/en-us/community/posts/360062334692-FilterAlignmentArtifacts-error
    # More testing is required.
    # TODO: Figure out why this isn't working. Low priority - experimental feature.
    if (defined(realignment_index_bundle)) {
        call FilterAlignmentArtifacts {
            input:
                ref_fasta = ref_fasta,
                ref_fai = ref_fai,
                ref_dict = ref_dict,
                bam = tumor_bam,
                bai = tumor_bai,
                realignment_index_bundle = select_first([realignment_index_bundle]),
                realignment_extra_args = realignment_extra_args,
                compress = compress,
                output_name = filtered_name,
                input_vcf = Filter.filtered_vcf,
                input_vcf_idx = Filter.filtered_vcf_idx,
                runtime_params = standard_runtime,
                mem_mb = filter_alignment_artifacts_mem,
                mem_pad = command_mem_padding
        }
    }

    File filter_output_vcf = select_first([FilterAlignmentArtifacts.filtered_vcf, Filter.filtered_vcf])
    File filter_output_vcf_idx = select_first([FilterAlignmentArtifacts.filtered_vcf_idx, Filter.filtered_vcf_idx])

    output {
        File filtered_vcf = filter_output_vcf  # select_first([FilterAlignmentArtifacts.filtered_vcf, Filter.filtered_vcf])
        File filtered_vcf_idx = filter_output_vcf_idx  # select_first([FilterAlignmentArtifacts.filtered_vcf_idx, Filter.filtered_vcf_idx])
        File filtering_stats = Filter.filtering_stats
        File mutect_stats = MergeStats.merged_stats
        File? contamination_table = CalculateContamination.contamination_table
        File? bamout = MergeBamOuts.merged_bam_out
        File? bamout_index = MergeBamOuts.merged_bam_out_index
        File? maf_segments = CalculateContamination.maf_segments
        File? read_orientation_model_params = LearnReadOrientationModel.artifact_prior_table
    }
}

# ================ #
# TASK DEFINITIONS #
# ================ #

task SplitIntervals {
    input {
      File? intervals
      File ref_fasta
      File ref_fai
      File ref_dict
      Int scatter_count
      String? split_intervals_extra_args

      # runtime
      Runtime runtime_params
    }

    command {
        set -e
        export GATK_LOCAL_JAR=~{default="/gatk/gatk.jar" runtime_params.gatk_override}

        mkdir interval-files
        gatk --java-options "-Xmx~{runtime_params.command_mem}m -Xms~{runtime_params.command_mem - 1000}m" SplitIntervals \
            -R ~{ref_fasta} \
            ~{"-L " + intervals} \
            -scatter ~{scatter_count} \
            -O interval-files \
            ~{split_intervals_extra_args}
        cp interval-files/*.interval_list .
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        Array[File] interval_files = glob("*.interval_list")
    }
}

task M2 {
    input {
      File? intervals
      File ref_fasta
      File ref_fai
      File ref_dict
      File tumor_bam
      File tumor_bai
      File? normal_bam
      File? normal_bai
      File? pon
      File? pon_idx
      File? gnomad
      File? gnomad_idx
      String? m2_extra_args
      Boolean? make_bamout
      Boolean? run_ob_filter
      Boolean compress
      File? gga_vcf
      File? gga_vcf_idx
      File? variants_for_contamination
      File? variants_for_contamination_idx
      File? gatk_override
      # runtime
      String gatk_docker
      Int mem_mb = 5000
      Int mem_pad = 1000
      Int? preemptible
      Int? max_retries
      Int? disk_space
      Int cpu = 4
      Boolean use_ssd = false
    }

    String output_vcf = "output" + if compress then ".vcf.gz" else ".vcf"
    String output_vcf_idx = output_vcf + if compress then ".tbi" else ".idx"

    String output_stats = output_vcf + ".stats"

    Int machine_mem = mem_mb
    Int cpu_mult = if cpu > 1 then cpu - 1 else 1
    Int command_mem = machine_mem - mem_pad

    # DNAnexus compatability: get the filename of all optional index files
    String normal_bai_def = if defined(normal_bai) then "defined" else "undefined"
    String pon_idx_def = if defined(pon_idx) then "defined" else "undefined"
    String gnomad_idx_def = if defined(gnomad_idx) then "defined" else "undefined"
    String gga_vcf_idx_def = if defined(gga_vcf_idx) then "defined" else "undefined"
    String variants_for_contamination_idx_def = if defined(variants_for_contamination_idx) then "defined" else "undefined"

    parameter_meta{
      intervals: {localization_optional: true}
      ref_fasta: {localization_optional: true}
      ref_fai: {localization_optional: true}
      ref_dict: {localization_optional: true}
      tumor_bam: {localization_optional: true}
      tumor_bai: {localization_optional: true}
      normal_bam: {localization_optional: true}
      normal_bai: {localization_optional: true}
      pon: {localization_optional: true}
      pon_idx: {localization_optional: true}
      gnomad: {localization_optional: true}
      gnomad_idx: {localization_optional: true}
      gga_vcf: {localization_optional: true}
      gga_vcf_idx: {localization_optional: true}
      variants_for_contamination: {localization_optional: true}
      variants_for_contamination_idx: {localization_optional: true}
    }

    command <<<
        set -e

        export GATK_LOCAL_JAR=~{default="/gatk/gatk.jar" gatk_override}

        # We need to create these files regardless, even if they stay empty
        touch bamout.bam
        touch f1r2.tar.gz
        echo "" > normal_name.txt

        # DNAnexus compatability: echo optional index filenames to ensure they get localized
        OPT_VAR_DEFINED="~{normal_bai_def}"
        OPT_VAR_DEFINED="~{pon_idx_def}"
        OPT_VAR_DEFINED="~{gnomad_idx_def}"
        OPT_VAR_DEFINED="~{gga_vcf_idx_def}"
        OPT_VAR_DEFINED="~{variants_for_contamination_idx_def}"

        gatk --java-options "-Xmx~{command_mem}m -Xms~{command_mem - 1000}m" GetSampleName -R ~{ref_fasta} -I ~{tumor_bam} -O tumor_name.txt -encode
        tumor_command_line="-I ~{tumor_bam} -tumor `cat tumor_name.txt`"

        if [[ ! -z "~{normal_bam}" ]]; then
            gatk --java-options "-Xmx~{command_mem}m -Xms~{command_mem - 1000}m" GetSampleName -R ~{ref_fasta} -I ~{normal_bam} -O normal_name.txt -encode
            normal_command_line="-I ~{normal_bam} -normal `cat normal_name.txt`"
        fi

        gatk --java-options "-Xmx~{command_mem}m -Xms~{command_mem - 1000}m" Mutect2 \
            -R ~{ref_fasta} \
            $tumor_command_line \
            $normal_command_line \
            ~{"--germline-resource " + gnomad} \
            ~{"-pon " + pon} \
            ~{"-L " + intervals} \
            ~{"--alleles " + gga_vcf} \
            -O "~{output_vcf}" \
            --native-pair-hmm-threads ~{cpu} \
            ~{true='--bam-output bamout.bam' false='' select_first([make_bamout, false])} \
            ~{true='--f1r2-tar-gz f1r2.tar.gz' false='' select_first([run_ob_filter, false])} \
            ~{m2_extra_args}

        m2_exit_code=$?

        ### GetPileupSummaries

        # If the variants for contamination and the intervals for this scatter don't intersect, GetPileupSummaries
        # throws an error.  However, there is nothing wrong with an empty intersection for our purposes; it simply doesn't
        # contribute to the merged pileup summaries that we create downstream.  We implement this by with array outputs.
        # If the tool errors, no table is created and the glob yields an empty array.
        set +e

        if [[ ! -z "~{variants_for_contamination}" ]]; then
            gatk --java-options "-Xmx~{command_mem}m -Xms~{command_mem - 1000}m" GetPileupSummaries -R ~{ref_fasta} -I ~{tumor_bam} ~{"--interval-set-rule INTERSECTION -L " + intervals} \
                -V ~{variants_for_contamination} -L ~{variants_for_contamination} -O tumor-pileups.table

            if [[ ! -z "~{normal_bam}" ]]; then
                gatk --java-options "-Xmx~{command_mem}m -Xms~{command_mem - 1000}m" GetPileupSummaries -R ~{ref_fasta} -I ~{normal_bam} ~{"--interval-set-rule INTERSECTION -L " + intervals} \
                    -V ~{variants_for_contamination} -L ~{variants_for_contamination} -O normal-pileups.table
            fi
        fi

        # the script only fails if Mutect2 itself fails
        exit $m2_exit_code
    >>>

    runtime {
        docker: gatk_docker
        bootDiskSizeGb: 12
        memory: machine_mem + " MB"
        disks: "local-disk " + select_first([disk_space, 100]) + if use_ssd then " SSD" else " HDD"
        preemptible: select_first([preemptible, 10])
        maxRetries: select_first([max_retries, 0])
        cpu: select_first([cpu, 4])
    }

    output {
        File unfiltered_vcf = "~{output_vcf}"
        File unfiltered_vcf_idx = "~{output_vcf_idx}"
        File output_bamOut = "bamout.bam"
        File stats = "~{output_stats}"
        File f1r2_counts = "f1r2.tar.gz"
        File? tumor_pileups = "tumor-pileups.table"
        File? normal_pileups = "normal-pileups.table"
    }
}

# Learning step of the orientation bias mixture model, which is the recommended orientation bias filter as of September 2018
task LearnReadOrientationModel {
    input {
      Array[File] f1r2_tar_gz
      Runtime runtime_params
      String output_name
      Int mem_mb = 5000
      Int mem_pad = 1000
    }

    Int machine_mem = mem_mb
    Int cpu_mult = if runtime_params.cpu > 1 then runtime_params.cpu - 1 else 1
    Int command_mem = machine_mem - mem_pad

    command {
        set -e
        export GATK_LOCAL_JAR=~{default="/gatk/gatk.jar" runtime_params.gatk_override}

        gatk --java-options "-Xmx~{command_mem}m -Xms~{command_mem - 1000}m" LearnReadOrientationModel \
            -I ~{sep=" -I " f1r2_tar_gz} \
            -O "~{output_name}-artifact-priors.tar.gz"
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File artifact_prior_table = "~{output_name}-artifact-priors.tar.gz"
    }

}

task MergeVCFs {
    input {
      Array[File] input_vcfs
      Array[File] input_vcf_indices
      String output_name
      Boolean compress
      Runtime runtime_params
    }

    String output_vcf = output_name + if compress then ".vcf.gz" else ".vcf"
    String output_vcf_idx = output_vcf + if compress then ".tbi" else ".idx"

    # using MergeVcfs instead of GatherVcfs so we can create indices
    # WARNING 2015-10-28 15:01:48 GatherVcfs  Index creation not currently supported when gathering block compressed VCFs.
    command {
        set -e
        export GATK_LOCAL_JAR=~{default="/gatk/gatk.jar" runtime_params.gatk_override}
        gatk --java-options "-Xmx~{runtime_params.command_mem}m -Xms~{runtime_params.command_mem - 1000}m" MergeVcfs -I ~{sep=' -I ' input_vcfs} -O ~{output_vcf}
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File merged_vcf = "~{output_vcf}"
        File merged_vcf_idx = "~{output_vcf_idx}"
    }
}

task MergeBamOuts {
    input {
      File ref_fasta
      File ref_fai
      File ref_dict
      Array[File]+ bam_outs
      String output_vcf_name
      Runtime runtime_params
      Int? disk_space   #override to request more disk than default small task params
    }

    command <<<
        # This command block assumes that there is at least one file in bam_outs.
        #  Do not call this task if len(bam_outs) == 0
        set -e
        export GATK_LOCAL_JAR=~{default="/gatk/gatk.jar" runtime_params.gatk_override}
        gatk --java-options "-Xmx~{runtime_params.command_mem}m -Xms~{runtime_params.command_mem - 1000}m" GatherBamFiles \
            -I ~{sep=" -I " bam_outs} -O unsorted.out.bam -R ~{ref_fasta}

        # We must sort because adjacent scatters may have overlapping (padded) assembly regions, hence
        # overlapping bamouts

        gatk --java-options "-Xmx~{runtime_params.command_mem}m -Xms~{runtime_params.command_mem - 1000}m" SortSam -I unsorted.out.bam \
            -O ~{output_vcf_name}.out.bam \
            --SORT_ORDER coordinate -VALIDATION_STRINGENCY LENIENT
        gatk --java-options "-Xmx~{runtime_params.command_mem}m -Xms~{runtime_params.command_mem - 1000}m" BuildBamIndex -I ~{output_vcf_name}.out.bam -VALIDATION_STRINGENCY LENIENT
    >>>

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + select_first([disk_space, runtime_params.disk]) + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File merged_bam_out = "~{output_vcf_name}.out.bam"
        File merged_bam_out_index = "~{output_vcf_name}.out.bai"
    }
}

task MergeStats {
    input {
      Array[File]+ stats
      String output_name
      Runtime runtime_params
    }

    command {
        set -e
        export GATK_LOCAL_JAR=~{default="/gatk/gatk.jar" runtime_params.gatk_override}


        gatk --java-options "-Xmx~{runtime_params.command_mem}m -Xms~{runtime_params.command_mem - 1000}m" MergeMutectStats \
            -stats ~{sep=" -stats " stats} -O "~{output_name}-merged.stats"
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File merged_stats = "~{output_name}-merged.stats"
    }
}

task MergePileupSummaries {
    input {
      Array[File] input_tables
      String output_name
      File ref_dict
      Runtime runtime_params
    }

    command {
        set -e
        export GATK_LOCAL_JAR=~{default="/gatk/gatk.jar" runtime_params.gatk_override}

        gatk --java-options "-Xmx~{runtime_params.command_mem}m -Xms~{runtime_params.command_mem - 1000}m" GatherPileupSummaries \
        --sequence-dictionary ~{ref_dict} \
        -I ~{sep=' -I ' input_tables} \
        -O ~{output_name}.tsv
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File merged_table = "~{output_name}.tsv"
    }
}

task CalculateContamination {
    input {
      String? intervals
      File tumor_pileups
      File? normal_pileups
      String output_name
      Runtime runtime_params
    }

    command {
        set -e

        export GATK_LOCAL_JAR=~{default="/gatk/gatk.jar" runtime_params.gatk_override}

        gatk --java-options "-Xmx~{runtime_params.command_mem}m -Xms~{runtime_params.command_mem - 1000}m" CalculateContamination -I ~{tumor_pileups} \
        -O "~{output_name}-contamination.table" --tumor-segmentation "~{output_name}-segments.table" ~{"-matched " + normal_pileups}
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File contamination_table = "~{output_name}-contamination.table"
        File maf_segments = "~{output_name}-segments.table"
    }
}

task Filter {
    input {
      File? intervals
      File ref_fasta
      File ref_fai
      File ref_dict
      File unfiltered_vcf
      File unfiltered_vcf_idx
      String output_name
      Boolean compress
      File? mutect_stats
      File? artifact_priors_tar_gz
      File? contamination_table
      File? maf_segments
      String? m2_extra_filtering_args

      Runtime runtime_params
      Int? disk_space
    }

    String output_vcf = output_name + if compress then ".vcf.gz" else ".vcf"
    String output_vcf_idx = output_vcf + if compress then ".tbi" else ".idx"

    parameter_meta{
      ref_fasta: {localization_optional: true}
      ref_fai: {localization_optional: true}
      ref_dict: {localization_optional: true}
    }

    command {
        set -e

        export GATK_LOCAL_JAR=~{default="/gatk/gatk.jar" runtime_params.gatk_override}

        gatk --java-options "-Xmx~{runtime_params.command_mem}m -Xms~{runtime_params.command_mem - 1000}m" FilterMutectCalls -V ~{unfiltered_vcf} \
            -R ~{ref_fasta} \
            -O ~{output_vcf} \
            ~{"--contamination-table " + contamination_table} \
            ~{"--tumor-segmentation " + maf_segments} \
            ~{"--ob-priors " + artifact_priors_tar_gz} \
            ~{"-stats " + mutect_stats} \
            --filtering-stats "~{output_name}.filtering.stats" \
            ~{m2_extra_filtering_args}
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + select_first([disk_space, runtime_params.disk]) + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File filtered_vcf = "~{output_vcf}"
        File filtered_vcf_idx = "~{output_vcf_idx}"
        File filtering_stats = "~{output_name}.filtering.stats"
    }
}

task FilterAlignmentArtifacts {
    input {
      File ref_fasta
      File ref_fai
      File ref_dict
      File input_vcf
      File input_vcf_idx
      File bam
      File bai
      String output_name
      Boolean compress
      File realignment_index_bundle
      String? realignment_extra_args
      Runtime runtime_params
      Int mem_mb = 5000
      Int mem_pad = 1000
    }

    String output_vcf = output_name + if compress then ".vcf.gz" else ".vcf"
    String output_vcf_idx = output_vcf +  if compress then ".tbi" else ".idx"

    Int machine_mem = mem_mb
    Int cpu_mult = if runtime_params.cpu > 1 then runtime_params.cpu - 1 else 1
    Int command_mem = machine_mem - mem_pad

    parameter_meta{
      ref_fasta: {localization_optional: true}
      ref_fai: {localization_optional: true}
      ref_dict: {localization_optional: true}
      input_vcf: {localization_optional: true}
      input_vcf_idx: {localization_optional: true}
      bam: {localization_optional: true}
      bai: {localization_optional: true}
    }

    command {
        set -e

        export GATK_LOCAL_JAR=~{default="/gatk/gatk.jar" runtime_params.gatk_override}

        gatk --java-options "-Xmx~{command_mem}m -Xms~{command_mem - 1000}m" FilterAlignmentArtifacts \
            -R ~{ref_fasta} \
            -V ~{input_vcf} \
            -I ~{bam} \
            --bwa-mem-index-image ~{realignment_index_bundle} \
            ~{realignment_extra_args} \
            -O ~{output_vcf}
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File filtered_vcf = "~{output_vcf}"
        File filtered_vcf_idx = "~{output_vcf_idx}"
    }
}
