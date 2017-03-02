import os
import sys
from snakemake.utils import report
from subprocess import check_output


def read_count(fastq):
    total = 0
    count_file = fastq + '.count'
    if os.path.exists(fastq) and os.path.getsize(fastq) > 100:
        if not os.path.exists(count_file):
            check_output("awk '{n++}END{print n/4}' %s > %s" % (fastq, fastq + '.count'), shell=True)
        with open(count_file) as fh:
            for line in fh:
                total = int(line.strip())
                break
    return total


def get_samples(eid, min_reads=1000):
    if not eid:
        return [], []

    min_reads = int(min_reads)
    samples = set()
    omitted = set()
    input_dir = os.path.join("results", eid, "demux")

    for f in os.listdir(input_dir):

        if (f.endswith("fastq") or f.endswith("fq")) and ("_r1" in f or "_R1" in f):

            sample_id = f.partition(".")[0].partition("_")[0]
            count = read_count(os.path.join(input_dir, f))

            if count >= min_reads:
                samples.add(sample_id)

            else:
                print("Omitting sample: %s (%d reads)" % (sample_id, count), file=sys.stderr)
                omitted.add(sample_id)

    return samples, omitted


def fix_tax_entry(tax, kingdom="?"):
    """
    >>> t = "p:Basidiomycota,c:Tremellomycetes,o:Tremellales,f:Tremellales_fam_Incertae_sedis,g:Cryptococcus"
    >>> fix_tax_entry(t, "Fungi")
    'k__Fungi,p__Basidiomycota,c__Tremellomycetes,o__Tremellales,f__Tremellales_fam_Incertae_sedis,g__Cryptococcus,s__?'
    """
    if tax == "" or tax == "*":
        taxonomy = dict()
    else:
        taxonomy = dict(x.split(":") for x in tax.split(","))
    if "d" in taxonomy and not "k" in taxonomy:
        taxonomy["k"] = taxonomy["d"]
    else:
        taxonomy["k"] = kingdom

    new_taxonomy = []
    for idx in "kpcofgs":
        new_taxonomy.append("%s__%s" % (idx, taxonomy.get(idx, "?")))
    return ",".join(new_taxonomy)


def fix_fasta_tax_entry(tax, kingdom="?"):
    """
    >>> t = ">OTU_7;tax=p:Basidiomycota,c:Microbotryomycetes,o:Sporidiobolales,f:Sporidiobolales_fam_Incertae_sedis,g:Rhodotorula;"
    >>> fix_fasta_tax_entry(t)
    '>OTU_7;tax=k__?,p__Basidiomycota,c__Microbotryomycetes,o__Sporidiobolales,f__Sporidiobolales_fam_Incertae_sedis,g__Rhodotorula,s__?;'
    """
    toks = tax.split(";")
    otu = toks[0]
    tax_piece = toks[1]
    if not tax_piece.startswith("tax"):
        raise ValueError
    sequence_tax = tax_piece.split("=")[1]
    new_tax = fix_tax_entry(sequence_tax, kingdom)
    return "%s;tax=%s;" % (toks[0], new_tax)


PROTOCOL_VERSION = "1.0.3"
USEARCH_VERSION = check_output("usearch --version", shell=True).strip()
VSEARCH_VERSION = check_output("vsearch --version", shell=True).strip()
# This is imperfect for vsearch...
CLUSTALO_VERSION = check_output("clustalo --version", shell=True).strip()
SAMPLES, OMITTED = get_samples(config.get("eid", None), config.get("minimum_reads", 1000))
# name output folder appropriately
CLUSTER_THRESHOLD = 100 - config['clustering']['percent_of_allowable_difference']
METHOD = config["annotation_method"]


rule all:
    input:
        expand("results/{eid}/logs/quality_filtering_stats.txt", eid=config['eid']),
        expand("results/{eid}/demux/{sample}_R1.fastq", eid=config['eid'], sample=SAMPLES),
        expand("results/{eid}/demux/{sample}_R2.fastq", eid=config['eid'], sample=SAMPLES),
        expand("results/{eid}/logs/{sample}_R1.fastq.count", eid=config['eid'], sample=SAMPLES),
        expand("results/{eid}/logs/{sample}_filtered_R1.fastq.count", eid=config['eid'], sample=SAMPLES),
        expand("results/{eid}/logs/{sample}_merged.fastq.count", eid=config['eid'], sample=SAMPLES),
        expand("results/{eid}/{pid}/{method}/OTU.biom", eid=config['eid'], pid=CLUSTER_THRESHOLD, method=METHOD),
        expand("results/{eid}/{pid}/OTU.tree", eid=config['eid'], pid=CLUSTER_THRESHOLD, method=METHOD),
        expand("results/{eid}/{pid}/{method}/README.html", eid=config['eid'], pid=CLUSTER_THRESHOLD, method=METHOD),
        expand("results/{eid}/{pid}/{method}/PROTOCOL_VERSION", eid=config['eid'], pid=CLUSTER_THRESHOLD, method=METHOD)


rule version:
    output: "results/{eid}/{pid}/{method}/PROTOCOL_VERSION".format(eid=config['eid'], pid=CLUSTER_THRESHOLD, method=METHOD)
    shell: 'echo "hundo: {PROTOCOL_VERSION}" > {output}'


rule make_tax_database:
    input:
        fasta = config['utax_database']['fasta'],
        trained_parameters = config['utax_database']['trained_parameters']
    output: os.path.splitext(config['utax_database']['trained_parameters'])[0] + '.udb'
    version: USEARCH_VERSION
    message: "Creating a UTAX database trained on {input.fasta} using {input.trained_parameters}"
    shell: "usearch -makeudb_utax {input.fasta} -taxconfsin {input.trained_parameters} -output {output}"

# Only for usearch
rule make_uchime_database:
    input: config['chimera_database']['fasta']
    output: os.path.splitext(config['chimera_database']['fasta'])[0] + '.udb'
    version: USEARCH_VERSION
    message: "Creating chimera reference index based on {input}"
    shell: "usearch -makeudb_usearch {input} -output {output}"


rule make_blast_db:
    input: config['blast_database']['fasta']
    output: expand(config['blast_database']['fasta'] + ".{idx}", idx=['nhr', 'nin', 'nsq'])
    message: "Formatting BLAST database"
    shell: "makeblastdb -in {input} -dbtype nucl"


rule count_raw_reads:
    input: "results/{eid}/demux/{sample}_R1.fastq"
    output: "results/{eid}/logs/{sample}_R1.fastq.count"
    shell: "awk '{{n++}}END{{print n/4}}' {input} > {output}"


rule quality_filter_reads:
    input:
        r1 = "results/{eid}/demux/{sample}_R1.fastq",
        r2 = "results/{eid}/demux/{sample}_R2.fastq"
    output:
        r1 = temp("results/{eid}/quality_filter/{sample}_R1.fastq"),
        r2 = temp("results/{eid}/quality_filter/{sample}_R2.fastq"),
        stats = "results/{eid}/quality_filter/{sample}_quality_filtering_stats.txt"
    message: "Filtering reads using BBDuk2 to remove adapters and phiX with matching kmer length of {params.k} at a hamming distance of {params.hdist} and quality trim both ends to Q{params.quality}. Reads shorter than {params.minlength} were discarded."
    params:
        lref = config['filtering']['adapters'],
        rref = config['filtering']['adapters'],
        fref = config['filtering']['contaminants'],
        mink = config['filtering']['mink'],
        quality = config['filtering']['minimum_base_quality'],
        hdist = config['filtering']['allowable_kmer_mismatches'],
        k = config['filtering']['reference_kmer_match_length'],
        qtrim = "rl",
        minlength = config['filtering']['minimum_passing_read_length']
    threads: config.get("threads", 1)
    shell: """bbduk2.sh -Xmx8g in={input.r1} in2={input.r2} out={output.r1} out2={output.r2} \
                  rref={params.rref} lref={params.lref} fref={params.fref} mink={params.mink} \
                  stats={output.stats} hdist={params.hdist} k={params.k} \
                  trimq={params.quality} qtrim={params.qtrim} threads={threads} \
                  minlength={params.minlength} overwrite=true"""


rule count_filtered_reads:
    input: "results/{eid}/quality_filter/{sample}_R1.fastq"
    output: "results/{eid}/logs/{sample}_filtered_R1.fastq.count"
    shell: "awk '{{n++}}END{{print n/4}}' {input} > {output}"


rule combine_filtering_stats:
    input: expand("results/{eid}/quality_filter/{sample}_quality_filtering_stats.txt", eid=config['eid'], sample=SAMPLES)
    output: "results/{eid}/logs/quality_filtering_stats.txt".format(eid=config['eid'])
    shell: "cat {input} > {output}"


# makes default option 'vsearch'
if config["merging"].get("program", "vsearch"):
    rule merge_reads:
        input:
            r1 = "results/{eid}/quality_filter/{sample}_R1.fastq",
            r2 = "results/{eid}/quality_filter/{sample}_R2.fastq"
        output: temp("results/{eid}/demux/{sample}_merged.fastq")
        version: VSEARCH_VERSION
        message: "Merging paired-end reads with VSEARCH at a minimum merge length of {params.minimum_merge_length}"
        params:
            minimum_merge_length = config["merging"].get("minimum_merge_length", 100)
        log:
            "results/{eid}/{pid}/logs/fastq_mergepairs.log".format(eid=config['eid'], pid=CLUSTER_THRESHOLD)
        shell:
            # need to ensure headers are compatible with all downstream trajectories (or limit those trajectories)
            # This will add the usearch samples annotation.
            #            -label_suffix \;sample={wildcards.sample}\; \
            """vsearch -fastq_mergepairs {input.r1} -reverse {input.r2} \
            -label_suffix \;sample={wildcards.sample}\; \
            -fastq_minmergelen {params.minimum_merge_length} \
            -fastqout {output} -log {log}"""
else:
    rule merge_reads:
        input:
            r1 = "results/{eid}/quality_filter/{sample}_R1.fastq",
            r2 = "results/{eid}/quality_filter/{sample}_R2.fastq"
        output: temp("results/{eid}/demux/{sample}_merged.fastq")
        version: USEARCH_VERSION
        message: "Merging paired-end reads with USEARCH at a minimum merge length of {params.minimum_merge_length}"
        params: minimum_merge_length = config['merging']['minimum_merge_length']
        log: "results/{eid}/{pid}/logs/fastq_mergepairs.log".format(eid=config['eid'], pid=CLUSTER_THRESHOLD)
        shell: """usearch -fastq_mergepairs {input.r1} -relabel @ -sample {wildcards.sample} \
                      -fastq_minmergelen {params.minimum_merge_length} \
                      -fastqout {output} -log {log}"""


rule count_joined_reads:
    input: "results/{eid}/demux/{sample}_merged.fastq"
    output: "results/{eid}/logs/{sample}_merged.fastq.count"
    shell: "awk '{{n++}}END{{print n/4}}' {input} > {output}"

# When using vsearch, reads have sample=; annotations, but not qiime compatible labels
if config["merging"].get("program", "vsearch"):
    rule combine_merged_reads:
        input: expand("results/{eid}/demux/{sample}_merged.fastq", eid=config['eid'], sample=SAMPLES)
        output: "results/{eid}/merged.fastq"
        message: "Concatenating the merged reads into a single file"
        shell: "cat {input} > {output}"
else:
    rule combine_merged_reads:
        input: expand("results/{eid}/demux/{sample}_merged.fastq", eid=config['eid'], sample=SAMPLES)
        output: "results/{eid}/merged.fastq"
        message: "Concatenating the merged reads into a single file"
        shell: "cat {input} > {output}"


if config["filtering"].get("program", "vsearch"):
    rule fastq_filter:
        #input: expand("results/{eid}/demux/{sample}_merged.fastq", eid=config['eid'], sample=SAMPLES) # Better??
        input: "results/{eid}/merged.fastq"
        output: "results/{eid}/merged_%s.fasta" % str(config['filtering']['maximum_expected_error'])
        version: VSEARCH_VERSION
        message: "Filtering FASTQ with VSEARCH with an expected maximum error rate of {params.maxee}"
        params: maxee = config['filtering']['maximum_expected_error']
        log: "results/{eid}/{pid}/logs/fastq_filter.log".format(eid=config['eid'], pid=CLUSTER_THRESHOLD)
        shell: """vsearch -fastq_filter {input} -fastaout {output} \
                          -fastq_maxee {params.maxee} -log {log}"""
else:
    rule fastq_filter:
        input: "results/{eid}/merged.fastq"
        output: "results/{eid}/merged_%s.fasta" % str(config['filtering']['maximum_expected_error'])
        version: USEARCH_VERSION
        message: "Filtering FASTQ with USEARCH with an expected maximum error rate of {params.maxee}"
        params: maxee = config['filtering']['maximum_expected_error']
        log: "results/{eid}/{pid}/logs/fastq_filter.log".format(eid=config['eid'], pid=CLUSTER_THRESHOLD)
        shell: "usearch -fastq_filter {input} -fastq_maxee {params.maxee} -fastaout {output} -log {log}"

if config["dereplicating"].get("program", "vsearch"):
    rule dereplicate_sequences:
        input: rules.fastq_filter.output
        output: temp("results/{eid}/uniques.fasta")
        version: VSEARCH_VERSION
        message: "Dereplicating with VSEARCH"
        threads: config.get("threads", 1)
        log: "results/{eid}/{pid}/logs/uniques.log".format(eid=config['eid'], pid=CLUSTER_THRESHOLD)
        shell: """vsearch --derep_fulllength {input} --output {output} \
                  --sizeout --threads {threads} -log {log}"""
else:
    rule dereplicate_sequences:
        input: rules.fastq_filter.output
        output: temp("results/{eid}/uniques.fasta")
        version: USEARCH_VERSION
        message: "Dereplicating with USEARCH"
        threads: config.get("threads", 1)
        log: "results/{eid}/{pid}/logs/uniques.log".format(eid=config['eid'], pid=CLUSTER_THRESHOLD)
        shell: "usearch -fastx_uniques {input} -fastaout {output} -sizeout -threads {threads} -log {log}"

if config["chimera_checking"]['uchime_denovo_prefilter']:
    rule optional_chimera_prefilter:
        input: rules.dereplicate_sequences.output
        output: temp("results/{eid}/uniques_uchime_denovo.fasta")
        version: VSEARCH_VERSION
        message: "Chimera checking using UCHIME de novo as implimented in VSEARCH"
        log: "results/{eid}/{pid}/logs/uniques_uchime_denovo.log".format(eid=config['eid'], pid=CLUSTER_THRESHOLD)
        shell: """vsearch --uchime_denovo {input} \--nonchimeras {output} \
                  --strand plus --sizein --sizeout \
                  --log {log}"""
else:
    rule optional_chimera_prefilter:
        input: rules.dereplicate_sequences.output
        output: rules.dereplicate_sequences.output
        message: "Skip chimera checking with UCHIME de novo"
        shell: "cp {input} {output}"


if config["clustering"].get("program", "vsearch"):
    rule cluster_sequences:
        input: rules.optional_chimera_prefilter.output
        output: temp("results/{eid}/{pid}/OTU_unfiltered.fasta")
        version: VSEARCH_VERSION
        message: "Clustering sequences with VSAERCH where OTUs have a minimum size of {params.minsize} and where the maximum difference between an OTU member sequence and the representative sequence of that OTU is {params.otu_id_pct}%"
        params:
            minsize = config['clustering']['minimum_sequence_abundance'],
            otu_id_pct = config['clustering']['vsearch_id']
        log: "results/{eid}/{pid}/logs/cluster_sequences.log"
        shell: """vsearch -cluster_size {input} -centroids {output} \
                  -minsize {params.minsize} -relabel OTU_ \
                  -id {params.otu_id_pct} -log {log}"""
else:
    rule cluster_sequences:
        input: rules.optional_chimera_prefilter.output
        output: temp("results/{eid}/{pid}/OTU_unfiltered.fasta")
        version: USEARCH_VERSION
        message: "Clustering sequences with USEARCH where OTUs have a minimum size of {params.minsize} and where the maximum difference between an OTU member sequence and the representative sequence of that OTU is {params.otu_radius_pct}%"
        params:
            minsize = config['clustering']['minimum_sequence_abundance'],
            otu_radius_pct = config['clustering']['percent_of_allowable_difference']
        log: "results/{eid}/{pid}/logs/cluster_sequences.log"
        shell: """usearch -cluster_otus {input} -minsize {params.minsize} -otus {output} -relabel OTU_ \
                      -otu_radius_pct {params.otu_radius_pct} -log {log}"""


# cluster
# -cluster_otus $out/uniques.fa -minsize 2 -otus $out/otus.fa -relabel Otu -log $out/cluster_otus.log
# followed by error correction
# -unoise $out/uniques.fa -fastaout $out/denoised.fa -relabel Den -log $out/unoise.log -minampsize 4


if config['chimera_filter_seed_sequences']:
    rule remove_chimeric_otus:
        input:
            fasta = rules.cluster_sequences.output,
            reference = rules.make_uchime_database.output
        output:
            notmatched = "results/{eid}/{pid}/OTU.fasta",
            chimeras = "results/{eid}/{pid}/chimeras.fasta"
        version: USEARCH_VERSION
        message: "Chimera filtering OTU seed sequences against %s" % config['chimera_database']['metadata']
        params: mode = config['filtering']['chimera_mode']
        threads: config.get("threads", 1)
        log: "results/{eid}/{pid}/logs/uchime_ref.log"
        shell: """usearch -uchime2_ref {input.fasta} -db {input.reference} -notmatched {output.notmatched} \
                      -chimeras {output.chimeras} -strand plus -threads {threads} -mode {params.mode} -log {log}"""
else:
    rule remove_chimeric_otus:
        input: rules.cluster_sequences.output
        output: "results/{eid}/{pid}/OTU.fasta"
        shell: "cp {input} {output}"


if METHOD == "utax":
    rule utax:
        input:
            fasta = "results/{eid}/{pid}/OTU.fasta",
            db = rules.make_tax_database.output
        output:
            fasta = temp("results/{eid}/{pid}/{method}/OTU_tax_utax.fasta"),
            txt = temp("results/{eid}/{pid}/{method}/OTU_tax_utax.txt")
        version: USEARCH_VERSION
        message: "Assigning taxonomies with UTAX algorithm using USEARCH with a confidence cutoff of {params.utax_cutoff}"
        params: utax_cutoff = config['taxonomy']['prediction_confidence_cutoff']
        threads: config.get("threads", 1)
        log: "results/{eid}/{pid}/{method}/logs/utax.log"
        shell: """usearch -utax {input.fasta} -db {input.db} -strand both -threads {threads} \
                      -fastaout {output.fasta} -utax_cutoff {params.utax_cutoff} \
                      -utaxout {output.txt} -log {log}"""


    rule fix_utax_taxonomy:
        input:
            fasta = rules.utax.output.fasta,
            txt = rules.utax.output.txt
        output:
            fasta = "results/{eid}/{pid}/{method}/OTU_tax.fasta",
            txt = "results/{eid}/{pid}/{method}/utax_hits.txt"
        params: kingdom = config['kingdom']
        message: "Altering taxa to reflect QIIME style annotation"
        run:
            with open(input.fasta) as ifh, open(output.fasta, 'w') as ofh:
                for line in ifh:
                    line = line.strip()
                    if not line.startswith(">OTU_"):
                        print(line, file=ofh)
                    else:
                        print(fix_fasta_tax_entry(line, params.kingdom), file=ofh)
            with open(input.txt) as ifh, open(output.txt, 'w') as ofh:
                for line in ifh:
                    toks = line.strip().split("\t")
                    print(toks[0], fix_tax_entry(toks[1], params.kingdom),
                          fix_tax_entry(toks[2], params.kingdom), toks[3], sep="\t", file=ofh)

else:
    rule blast:
        input:
            fasta = "results/{eid}/{pid}/OTU.fasta",
            db = rules.make_blast_db.output
        output: "results/{eid}/{pid}/blast/blast_hits.txt"
        params:
            P = config['taxonomy']['lca_cutoffs'],
            L = config['taxonomy']['prediction_confidence_cutoff'],
            db = config['blast_database']['fasta']
        threads: config.get("threads", 1)
        shell: """blastn -query {input.fasta} -db {params.db} -num_alignments 50 \
                      -outfmt "6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore" \
                      -out {output} -num_threads {threads}"""


    rule lca:
        input: rules.blast.output
        output: "results/{eid}/{pid}/blast/lca_assignments.txt"
        params:
            tax = config['blast_database']['taxonomy'],
            P = config['taxonomy']['lca_cutoffs'],
            L = config['taxonomy']['prediction_confidence_cutoff']
        shell: "resources/lca_src/lca -L {params.L} -P {params.P} -i {input} -r {params.tax} -o {output}"


    rule assignments_from_lca:
        input:
            tsv = rules.lca.output,
            fasta = "results/{eid}/{pid}/OTU.fasta"
        output: "results/{eid}/{pid}/{method}/OTU_tax.fasta"
        run:
            lca_results = {}
            with open(input.tsv[0]) as fh:
                for line in fh:
                    line = line.strip().split("\t")
                    # file has a header, but doesn't matter
                    tax = []
                    for i, level in enumerate('kpcofgs'):
                        try:
                            tax.append("%s__%s" % (level, line[i + 1]))
                        except IndexError:
                            # ensure unassigned
                            for t in line[1:]:
                                assert t == "?"
                            tax.append("%s__?" % level)
                    lca_results[line[0]] = tax
            with open(input.fasta) as fasta_file, open(output[0], "w") as outfile:
                    for line in fasta_file:
                        line = line.strip()
                        if not line.startswith(">"):
                            print(line, file=outfile)
                        else:
                            try:
                                print(">%s;tax=%s" % (line[1:], ",".join(lca_results[line[1:]])), file=outfile)
                            except KeyError:
                                print(">%s;tax=k__?,p__?,c__?,o__?,f__?,g__?,s__?" % line[1:], file=outfile)


rule compile_counts:
    input:
        fastq = rules.combine_merged_reads.output,
        fasta = "results/{eid}/{pid}/{method}/OTU_tax.fasta"
    output: "results/{eid}/{pid}/{method}/OTU.txt"
    params: threshold = config['mapping_to_otus']['read_identity_requirement']
    threads: config.get("threads", 1)
    shell:"""usearch -usearch_global {input.fastq} -db {input.fasta} -strand plus \
                 -id {params.threshold} -otutabout {output} -threads {threads}"""


rule biom:
    input: rules.compile_counts.output
    output: "results/{eid}/{pid}/{method}/OTU.biom"
    shadow: "shallow"
    shell: '''sed 's|\"||g' {input} | sed 's|\,|\;|g' > OTU_converted.txt
              biom convert -i OTU_converted.txt -o {output} --to-json \
                  --process-obs-metadata sc_separated --table-type "OTU table"'''


rule multiple_align:
    input: "results/{eid}/{pid}/OTU.fasta"
    output: "results/{eid}/{pid}/OTU_aligned.fasta"
    message: "Multiple alignment of samples using Clustal Omega"
    version: CLUSTALO_VERSION
    threads: config.get("threads", 1)
    shell: "clustalo -i {input} -o {output} --outfmt=fasta --threads {threads} --force"


rule newick_tree:
    input: "results/{eid}/{pid}/OTU_aligned.fasta"
    output: "results/{eid}/{pid}/OTU.tree"
    message: "Building tree from aligned OTU sequences with FastTree2"
    log: "results/{eid}/{pid}/logs/fasttree.log"
    shell: "FastTree -nt -gamma -spr 4 -log {log} -quiet {input} > {output}"


# TODO: will have to undergo major changes in the report and citations sections; will
# likely just convert to a simple bulleted list style format
rule report:
    input:
        file1 = "results/{eid}/{pid}/{method}/OTU.biom".format(eid=config['eid'], pid=CLUSTER_THRESHOLD, method=METHOD),
        file2 = "results/{eid}/{pid}/OTU.fasta".format(eid=config['eid'], pid=CLUSTER_THRESHOLD),
        file3 = "results/{eid}/{pid}/OTU.tree".format(eid=config['eid'], pid=CLUSTER_THRESHOLD),
        file4 = "results/{eid}/{pid}/{method}/OTU.txt".format(eid=config['eid'], pid=CLUSTER_THRESHOLD, method=METHOD),
        raw_counts = expand("results/{eid}/logs/{sample}_R1.fastq.count", eid=config['eid'], sample=SAMPLES),
        filtered_counts = expand("results/{eid}/logs/{sample}_filtered_R1.fastq.count", eid=config['eid'], sample=SAMPLES),
        merged_counts = expand("results/{eid}/logs/{sample}_merged.fastq.count", eid=config['eid'], sample=SAMPLES),
        css = "resources/report.css"
    shadow: "shallow"
    params:
        kmer_len = config['filtering']['reference_kmer_match_length'],
        ham_dist = config['filtering']['allowable_kmer_mismatches'],
        min_read_len = config['filtering']['minimum_passing_read_length'],
        min_merge_len = config['merging']['minimum_merge_length'],
        max_ee = config['filtering']['maximum_expected_error'],
        tax_cutoff = config['taxonomy']['prediction_confidence_cutoff'],
        tax_levels = config['taxonomy']['lca_cutoffs'],
        min_seq_abundance = config['clustering']['minimum_sequence_abundance'],
        samples = SAMPLES,
        minimum_reads = config['minimum_reads']
    output:
        html = "results/{eid}/{pid}/README.html"
    run:
        from biom import parse_table
        from biom.util import compute_counts_per_sample_stats
        from operator import itemgetter
        from numpy import std

        # writing up some methods
        if config["annotation_method"] == "blast":
            taxonomy_metadata = config["blast_database"]["metadata"]
            taxonomy_citation = config["blast_database"]["citation"]
            taxonomy_assignment = ("Taxonomy was assigned to OTU sequences using BLAST [6] "
                                   "alignments followed by least common ancestor assignments "
                                   "across {meta} [7].").format(meta=taxonomy_metadata)
            algorithm_citation = ('6. Camacho C., Coulouris G., Avagyan V., Ma N., '
                                  'Papadopoulos J., Bealer K., & Madden T.L. (2008) "BLAST+: '
                                  'architecture and applications." BMC Bioinformatics 10:421.')
        else:
            taxonomy_metadata = config["utax_database"]["metadata"]
            taxonomy_citation = config["utax_database"]["citation"]
            taxonomy_assignment = ("Taxonomy was assigned to OTU sequence using the UTAX [6]"
                                   "algorithm of USEARCH across {meta} [7]").format(meta=taxonomy_metadata)
            algorithm_citation = "7. http://drive5.com/usearch/manual/utax_algo.html"
        if config["chimera_filter_seed_sequences"]:
            chimera_info = ("This occurs *de novo* during clustering using the UCHIME algorithm and as reference-based on "
                            "the OTU seed sequences against {chimera}").format(chimera=config["chimera_database"]["metadata"])
            chimera_citation = "8. {cite}".format(cite=config["chimera_database"]["citation"])
            chimera_filtering = ("OTU seed sequences were filtered against {meta} [8] to identify "
                                 "chimeric OTUs using USEARCH.").format(meta=config["chimera_database"]["metadata"])
        else:
            chimera_info = "This occurs *de novo* during clustering using the UCHIME algorithm."
            chimera_citation = ""
            chimera_filtering = ""

        # omitted samples bulleted list
        if OMITTED:
            omitted_samples = "".join(["- %s\n" % i for i in OMITTED])
        else:
            omitted_samples = "- No samples were omitted.\n"

        # stats from the biom table
        summary_csv = "stats.csv"
        sample_summary_csv = "samplesummary.csv"
        samples_csv = "samples.csv"
        biom_per_sample_counts = {}
        biom_libraries = ""
        biom_observations = ""
        with open(input.file1) as fh, open(summary_csv, 'w') as sumout, open(samples_csv, 'w') as samout, open(sample_summary_csv, 'w') as samplesum:
            bt = parse_table(fh)
            biom_libraries = "[%s]" % ", ".join(map(str, bt.sum("sample")))
            biom_observations = "[%s]" % ", ".join(map(str, bt.sum("observation")))
            stats = compute_counts_per_sample_stats(bt)
            biom_per_sample_counts = stats[4]
            sample_counts = list(stats[4].values())

            # summary
            print("Samples", "Omitted Samples", "OTUs", "OTU Total Count", "OTU Table Density", sep=",", file=sumout)
            print(len(bt.ids()), len(OMITTED), len(bt.ids(axis='observation')), sum(sample_counts), bt.get_table_density(), sep=",", file=sumout)

            # sample summary within OTU table
            print("Minimum Count", "Maximum Count", "Median", "Mean", "Standard Deviation", sep=",", file=samplesum)
            print(stats[0], stats[1], stats[2], stats[3], std(sample_counts), sep=",", file=samplesum)

            for k, v in sorted(stats[4].items(), key=itemgetter(1)):
                print(k, '%1.1f' % v, sep=",", file=samout)

        # stats from count files
        sample_counts = {}

        for sample in params.samples:
            sample_counts[sample] = {}
            # get raw count
            for f in input.raw_counts:
                if "%s_R1.fastq.count" % sample in f:
                    with open(f) as fh:
                        for line in fh:
                            sample_counts[sample]['raw_counts'] = int(line.strip())
                            break
            # filtered count
            for f in input.filtered_counts:
                if "%s_filtered_R1.fastq.count" % sample in f:
                    with open(f) as fh:
                        for line in fh:
                            sample_counts[sample]['filtered_counts'] = int(line.strip())
                            break
            # merged count
            for f in input.merged_counts:
                if "%s_merged.fastq.count" % sample in f:
                    with open(f) as fh:
                        for line in fh:
                            sample_counts[sample]['merged_counts'] = int(line.strip())
                            break

        raw_counts = []
        filtered_counts = []
        merged_counts = []
        biom_counts = []
        samps = []
        # sort this by the raw counts total and get the strings for the report
        for s in sorted(sample_counts.items(), key=lambda k_v: k_v[1]['raw_counts']):
            samps.append(s[0])
            raw_counts.append(s[1]['raw_counts'])
            filtered_counts.append(s[1]['filtered_counts'])
            merged_counts.append(s[1]['merged_counts'])
            try:
                # read count contribution to OTUs
                biom_counts.append(biom_per_sample_counts[s[0]])
            except KeyError:
                biom_counts.append(0)

        # quoted strings within brackets
        samples_str = "['%s']" % "', '".join(map(str, samps))
        # non-quoted ints or floats within brackets
        raw_counts_str = "[%s]" % ", ".join(map(str, raw_counts))
        filtered_counts_str = "[%s]" % ", ".join(map(str, filtered_counts))
        merged_counts_str = "[%s]" % ", ".join(map(str, merged_counts))
        biom_counts_str = "[%s]" % ", ".join(map(str, biom_counts))

        report("""
        =============================================================
        README - {wildcards.eid}
        =============================================================

        .. raw:: html

            <script src="https://ajax.googleapis.com/ajax/libs/jquery/1.11.3/jquery.min.js"></script>
            <script src="https://code.highcharts.com/highcharts.js"></script>
            <script src="https://code.highcharts.com/modules/exporting.js"></script>
            <script type="text/javascript">
            $(function () {{
                $('#raw-count-plot').highcharts({{
                    chart: {{
                        type: 'column'
                    }},
                    title: {{
                        text: 'Sequence Counts'
                    }},
                    xAxis: {{
                        categories: {samples_str},
                        crosshair: true
                    }},
                    yAxis: {{
                        min: 0,
                        title: {{
                            text: 'Count'
                        }}
                    }},
                    tooltip: {{
                        headerFormat: '<span style="font-size:10px">{{point.key}}</span><table>',
                        pointFormat: '<tr><td style="color:{{series.color}};padding:0">{{series.name}}: </td>' +
                            '<td style="padding:0"><b>{{point.y:.1f}}</b></td></tr>',
                        footerFormat: '</table>',
                        shared: true,
                        useHTML: true
                    }},
                    credits: {{
                        enabled: false
                    }},
                    plotOptions: {{
                        column: {{
                            pointPadding: 0.2,
                            borderWidth: 0
                        }}
                    }},
                    series: [{{
                                name: 'Raw',
                                data: {raw_counts_str}
                            }},
                            {{
                                name: 'Filtered',
                                data: {filtered_counts_str},
                                visible: false
                            }},
                            {{
                                name: 'Merged',
                                data: {merged_counts_str},
                                visible: false
                            }},
                            {{
                                name: 'Assigned to OTUs',
                                data: {biom_counts_str},
                                visible: false
                            }}]
                    }});
            }});

            $(function() {{
              $('#library-sizes').highcharts({{
                chart: {{
                  type: 'column'
                }},
                title: {{
                  text: 'Library Sizes'
                }},
                legend: {{
                  enabled: false
                }},
                credits: {{
                  enabled: false
                }},
                exporting: {{
                  enabled: false
                }},
                tooltip: {{}},
                plotOptions: {{
                  column: {{
                      pointPadding: 0.2,
                      borderWidth: 0
                  }},
                  series: {{
                      color: '#A9A9A9'
                  }}
                }},
                xAxis: {{
                  title: {{
                    text: 'Number of Reads (Counts)'
                  }}
                }},
                yAxis: {{
                  title: {{
                    text: 'Number of Libraries'
                  }}
                }},
                series: [{{
                            name: 'Library',
                            data: binData({biom_libraries})
                        }}]
                }});
            }});

            $(function() {{
              $('#otu-totals').highcharts({{
                chart: {{
                  type: 'column'
                }},
                title: {{
                  text: 'OTU Totals'
                }},
                legend: {{
                  enabled: false
                }},
                credits: {{
                  enabled: false
                }},
                exporting: {{
                  enabled: false
                }},
                tooltip: {{}},
                plotOptions: {{
                  column: {{
                      pointPadding: 0.2,
                      borderWidth: 0
                  }},
                  series: {{
                      color: '#A9A9A9'
                  }}
                }},
                xAxis: {{
                  title: {{
                    text: 'Number of Reads (Counts)'
                  }}
                }},
                yAxis: {{
                  type: 'logarithmic',
                  minorTickInterval: 0.1,
                  title: {{
                    text: 'log(OTU counts)'
                  }}
                }},
                series: [{{
                            name: 'Observations',
                            data: binData({biom_observations})
                        }}]
                }});
            }});

            function binData(data) {{

              var hData = new Array(), //the output array
                size = data.length, //how many data points
                bins = Math.round(Math.sqrt(size)); //determine how many bins we need
              bins = bins > 50 ? 50 : bins; //adjust if more than 50 cells
              var max = Math.max.apply(null, data), //lowest data value
                min = Math.min.apply(null, data), //highest data value
                range = max - min, //total range of the data
                width = range / bins, //size of the bins
                bin_bottom, //place holders for the bounds of each bin
                bin_top;

              //loop through the number of cells
              for (var i = 0; i < bins; i++) {{

                //set the upper and lower limits of the current cell
                bin_bottom = min + (i * width);
                bin_top = bin_bottom + width;

                //check for and set the x value of the bin
                if (!hData[i]) {{
                  hData[i] = new Array();
                  hData[i][0] = bin_bottom + (width / 2);
                }}

                //loop through the data to see if it fits in this bin
                for (var j = 0; j < size; j++) {{
                  var x = data[j];

                  //adjust if it's the first pass
                  i == 0 && j == 0 ? bin_bottom -= 1 : bin_bottom = bin_bottom;

                  //if it fits in the bin, add it
                  if (x > bin_bottom && x <= bin_top) {{
                    !hData[i][1] ? hData[i][1] = 1 : hData[i][1]++;
                  }}
                }}
              }}
              $.each(hData, function(i, point) {{
                if (typeof point[1] == 'undefined') {{
                  hData[i][1] = 0;
                }}
              }});
              return hData;
            }}
            </script>

        .. contents::
            :backlinks: none

        Summary
        -------

        .. csv-table::
            :file: {summary_csv}
            :header-rows: 1

        .. raw:: html

            <div id="raw-count-plot" class="one-col"></div>
            <div>
                <div id="library-sizes" class="two-col-left"></div>
                <div id="otu-totals" class="two-col-right"></div>
            </div>

        Samples that were omitted due to low read count (less than {params.minimum_reads} sequences):

        {omitted_samples}

        Output
        ------

        Chimera Removal
        ***************

        {chimera_info}

        Biom Table
        **********

        Counts observed per sample as represented in the biom file (file1_). This count is
        representative of quality filtered reads that were assigned per sample to OTU seed
        sequences.

        .. csv-table::
            :file: {sample_summary_csv}
            :header-rows: 1

        Taxonomy was assigned to the OTU sequences at an overall cutoff of {params.tax_cutoff}%.

        Taxonomy database - {taxonomy_metadata}

        OTU Sequences
        *************

        The OTU sequences are available in FASTA format (file2_) and aligned as newick tree
        (file3_).

        To build the tree, sequences were aligned using Clustalo [1] and FastTree2 [2] was used
        to generate the phylogenetic tree.


        Methods
        -------

        Reads were quality filtered with BBDuk2 [3]
        to remove adapter sequences and PhiX with matching kmer length of {params.kmer_len}
        bp at a hamming distance of {params.ham_dist}. Reads shorter than {params.min_read_len} bp
        were discarded. Reads were merged using USEARCH [4] with a minimum length
        threshold of {params.min_merge_len} bp and maximum error rate of {params.max_ee}%. Sequences
        were dereplicated (minimum sequence abundance of {params.min_seq_abundance}) and clustered
        using the distance-based, greedy clustering method of USEARCH [5] at
        {CLUSTER_THRESHOLD}% pairwise sequence identity among operational taxonomic unit (OTU) member
        sequences. De novo prediction of chimeric sequences was performed using USEARCH during
        clustering. {taxonomy_assignment} {chimera_filtering}


        References
        ----------

        1. Sievers F, Wilm A, Dineen D, Gibson TJ, Karplus K, Li W, Lopez R, McWilliam H, Remmert M, Söding J, et al. 2011. Fast, scalable generation of high-quality protein multiple sequence alignments using Clustal Omega. Mol Syst Biol 7: 539
        2. Price MN, Dehal PS, Arkin AP. 2010. FastTree 2--approximately maximum-likelihood trees for large alignments. ed. A.F.Y. Poon. PLoS One 5: e9490
        3. Bushnell, B. (2014). BBMap: A Fast, Accurate, Splice-Aware Aligner. URL https://sourceforge.net/projects/bbmap/
        4. Edgar, RC (2010). Search and clustering orders of magnitude faster than BLAST, Bioinformatics 26(19), 2460-2461. doi: 10.1093/bioinformatics/btq461
        5. Edgar, RC (2013). UPARSE: highly accurate OTU sequences from microbial amplicon reads. Nat Methods.
        {algorithm_citation}
        7. {taxonomy_citation}
        {chimera_citation}


        All Files
        ---------

        More files are available in relation to this analysis than are presented here. They can
        be accessed from the results directory and are organized by your experiment ID
        ({wildcards.eid})::

            {wildcards.eid}/                                 # clustering pairwise identity threshold
                ├── blast
                │   ├── blast_hits.txt                  # raw blast hits per OTU seed seq
                │   ├── lca_assignments.txt             # raw lca results TSV from blast hits
                │   ├── OTU.biom                        # tax annotated biom (no metadata, no normalization)
                │   ├── OTU_tax.fasta                   # otu seqs with tax in FASTA header
                │   ├── OTU.txt                         # tab delimited otu table with taxonomy
                │   └── README.html                     # results report when annotation method is 'blast'
                ├── logs
                │   ├── cluster_sequences.log
                │   ├── fasttree.log
                │   └── uniques.log
                ├── OTU_aligned.fasta                   # multiple alignment file of otu seed seqs
                ├── OTU.fasta                           # otu seqs without taxonomy
                ├── OTU.tree                            # newick tree of multiple alignment
                ├── utax
                │   ├── OTU.biom                        # tax annotated biom (no metadata, no normalization)
                │   ├── OTU_tax.fasta                   # otu seqs with tax in FASTA header
                │   ├── OTU.txt                         # tab delimited otu table with taxonomy
                │   ├── README.html                     # results report when annotation method is 'utax'
                │   └── utax_hits.txt                   # raw UTAX hits per OTU seed seq
                ├── demux
                │   ├── *.fastq.count
                │   └── *.fastq
                ├── logs
                │   ├── quality_filtering_stats.txt
                │   └── *.count
                ├── merged_?.fasta                      # error corrected FASTA prior to clustering into OTU seqs
                ├── merged.fastq                        # all sample reads merged into single file with updated headers
                └── quality_filter
                    └── *.fastq                         # files that should have been cleaned up!

        Downloads
        ---------

        """, output.html, metadata="Author: " + config.get("author"),
        stylesheet=input.css, file1=input.file1, file2=input.file2, file3=input.file3,
        file4=input.file4)
