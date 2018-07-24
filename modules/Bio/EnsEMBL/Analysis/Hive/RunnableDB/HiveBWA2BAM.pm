# Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
# Copyright [2016-2018] EMBL-European Bioinformatics Institute
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
=pod

=head1 NAME

Bio::EnsEMBL::Analysis::RunnableDB::BWA




=head1 SYNOPSIS

my $runnableDB =  Bio::EnsEMBL::Analysis::RunnableDB::BWA->new( );

$runnableDB->fetch_input();
$runnableDB->run();

=head1 DESCRIPTION

This module uses BWA to process the alignment from the .sai files to create
a BAM file recording the pairing information if present

=head1 CONTACT

Post general queries to B<http://lists.ensembl.org/mailman/listinfo/dev>

=head1 APPENDIX
=cut

package Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveBWA2BAM;

use warnings ;
use strict;

use Bio::EnsEMBL::Analysis::Tools::Utilities qw(send_email);
use Bio::EnsEMBL::Analysis::Runnable::BWA2BAM;
use File::Spec::Functions qw(catfile);

use parent ('Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveBaseRunnableDB');


=head2 param_defaults

 Arg [1]    : None
 Description: Returns the default parameters
               _branch_to_flow_to => 1, it has to be the same branch as your accumulator and the branch the receiving job is
 Returntype : Hashref
 Exceptions : None

=cut

sub param_defaults {
  my ($self) = @_;

  return {
    %{$self->SUPER::param_defaults},
    _branch_to_flow_to => 1,
  }
}


=head2 fetch_input

 Arg [1]    : None
 Description: Retrieve the .sai files generated by BWA, choose the algorithm based on the 'is_paired' key and
              create a Bio::EnsEMBL::Analysis::Runnable::BWA2BAM object to run bwa sampe/samse
 Returntype : None
 Exceptions : None

=cut

sub fetch_input {
  my ($self) = @_;

  if ($self->param_is_defined('fastq')) {
    my $program = $self->param('wide_short_read_aligner');
    $self->throw("BWA program not defined in analysis\n") unless (defined $program);
    my $fastqfile;
    my $fastqpair;

    my $method = $self->param('is_paired') ? ' sampe '.$self->param('sampe_options') : ' samse '.$self->param('samse_options');
    foreach my $fastq (@{$self->param('fastq')}) {
        my $abs_filename = catfile($self->param('wide_input_dir'), $fastq->{filename});
        $self->throw("Fastq file $abs_filename not found\n") unless (-e $abs_filename);
        if ($fastq->{is_mate_1} == 1) {
            $fastqfile = $abs_filename;
        }
        else {
            $fastqpair = $abs_filename;
        }
    }
    my $analysis = $self->create_analysis;
    $analysis->parameters('-use_threads => '.$self->param('use_threads')) if ($self->param_is_defined('use_threads'));
    my $runnable = Bio::EnsEMBL::Analysis::Runnable::BWA2BAM->new
      (
       -analysis   => $analysis,
       -program    => $program,
       -fastq      => $fastqfile,
       -fastqpair  => $fastqpair,
       -options    => $method,
       -outdir     => $self->param('wide_output_dir'),
       -genome     => $self->param('wide_genome_file'),
       -samtools => $self->param('wide_samtools'),
       -header => $self->param('header_file'),
       -min_mapped => $self->param('min_mapped'),
       -min_paired => $self->param('min_paired'),
      );
      if ($self->param_is_defined('bam_prefix')) {
          $runnable->bam_prefix($self->param($self->param('bam_prefix')));
      }
    $self->runnable($runnable);
  }
  else {
    $self->input_job->autoflow(0);
    $self->complete_early('There is no fastq files for this job');
  }
}


=head2 write_output

 Arg [1]    : None
 Description: Dataflow the absolute name of the BAM file, accessible via $self->param('filename') on branch '_branch_to_flow_to'
              If the number of mapped reads and of paired reads are below the minimal, it sends an email
              but do not flow the data
 Returntype : None
 Exceptions : None

=cut

sub write_output {
  my $self = shift;

  my $output = $self->output;
  if (scalar(@$output) == 1) {
    $self->dataflow_output_id({filename => $output->[0]}, $self->param('_branch_to_flow_to'));
  }
  else {
    my $text = 'For '.$output->[0].":\nThe number of mapped reads is below the threshold of ".$self->param('min_mapped').': '.$output->[1];
    if ($output->[2]) {
      $text .= "\nThe number of paired reads is below the threshold of ".$self->param('min_paired').': '.$output->[2];
    }
    send_email($self->param('email'), $self->param('email'), '[genebuild rnaseq pipeline] '.$self->param('ID').' '.$self->param('SM').' low mapping', $text);
    $self->warning($text);
    $self->input_job->autoflow(0);
  }
}

1;
