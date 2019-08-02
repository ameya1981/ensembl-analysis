=head1 LICENSE

# Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
# Copyright [2016-2019] EMBL-European Bioinformatics Institute
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

=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

  Questions may also be sent to the Ensembl help desk at
  <http://www.ensembl.org/Help/Contact>.

=cut

=head1 NAME

Bio::EnsEMBL::Analysis::RunnableDB::MergeBamFiles - Merge BAM files

=head1 SYNOPSIS

{
  -logic_name => 'merged_tissue_file',
  -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveMergeBamFiles',
  -parameters => {
    java       => 'java',
    java_options  => '-Xmx2g',
    # If 0, do not use multithreading, faster but can use more memory.
    # If > 0, tells how many cpu to use for samtools or just to use multiple cpus for picard
    use_threading => $self->o('use_threads'),
    # Path to MergeSamFiles.jar
    picard_lib    => $self->o('picard_lib_jar'),
    # Use this default options for Picard: 'MAX_RECORDS_IN_RAM=20000000 CREATE_INDEX=true SORT_ORDER=coordinate ASSUME_SORTED=true VALIDATION_STRINGENCY=LENIENT'
    # You will need to change the options if you want to use samtools for merging
    options       => 'MAX_RECORDS_IN_RAM=20000000 CREATE_INDEX=true SORT_ORDER=coordinate ASSUME_SORTED=true VALIDATION_STRINGENCY=LENIENT',
    # target_db is the database where we will write the files in the data_file table
    # You can use store_datafile => 0, if you don't want to store the output file
    target_db => $self->o('blast_db'),
    disconnect_jobs => 1,
  },
  -rc_name    => '3GB_multithread',
  -flow_into => {
    1 => [ ':////accu?filename=[]' ],
  },
},

=head1 DESCRIPTION

Merge BAM files using either picard or samtools. Picard is the prefered choice.
It uses samtools to check if it was successfull. All the input files are retrieved
from the accu table of the Hive database and it stores the output file name in
the accu table on branch 1.

=head1 METHODS

=cut

package Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveMergeBamFiles;

use warnings ;
use strict;
use feature 'say';

use File::Copy;
use File::Spec;
use File::Basename qw(basename);

use Bio::EnsEMBL::DataFile;

use parent ('Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveBaseRunnableDB');


=head2 param_defaults

 Arg [1]    : None
 Description: Default values for this module are:
               bam_version => 1, this is for the name of the file
               rename_file => 1, if we don't merge, rename the file
               store_datafile => 1, store the file name in data_file
               _index_ext => 'bai',
               _file_ext => 'bam',
               _logic_name_ext => 'bam', This is for the data_file table
               _branch_to_flow_to => 1, This has to be the same as the accumulatorj
 Returntype : Hashref, containing all default parameters
 Exceptions : None

=cut

sub param_defaults {
  my ($self) = @_;

  return {
    %{$self->SUPER::param_defaults()},
    bam_version => 1,
    rename_file => 0,
    store_datafile => 1,
    _index_ext => 'bai',
    _file_ext => 'bam',
    _logic_name_ext => 'bam',
    accu_key => 'filename',
  }
}


=head2 fetch_input

 Arg [1]    : None
 Description: It will fetch all the BAM files. If there is only one file and the samtools option 
              -b is not used it will flow the name of the file on branch 1 with 'filename'
              If 'picard_lib' is defined it will use Picard to merge the files otherwise it will
              use samtools
 Returntype : None
 Exceptions : Throws if 'filename' is empty
              Throws if the filename is not an absolute path

=cut

sub fetch_input {
    my ($self) = @_;

    $self->create_analysis;
    my $sample_name;
    if($self->param('merge_star_tissues')) {
      my %tmp = %{$self->param_required('tissue_data')};
      my @tmp = keys(%tmp);
      $sample_name = $tmp[0];
      say "Tissue sample name: ".$sample_name;
      $self->param('sample_name',$sample_name);
    }

    if ($self->param('store_datafile')) {
      my $db = $self->get_database_by_name('target_db');
      $db->dbc->disconnect_when_inactive(1) if ($self->param('disconnect_jobs'));
      $self->hrdb_set_con($db, 'target_db');
    }
    my $outname = $self->param_is_defined('sample_name') ? $self->param('sample_name') : 'merged';
    if (!$self->param_is_defined('logic_name')) {
      $self->analysis->logic_name($self->param('species').'_'.$outname.'_rnaseq_'.$self->param('_logic_name_ext'));
    }
    if (!$self->param_is_defined('alignment_bam_file')) {
      $self->param('alignment_bam_file', File::Spec->catfile($self->param('output_dir'),
        join('.', $self->param_required('assembly_name'), $self->param_required('rnaseq_data_provider'), $outname, $self->param('bam_version'), $self->param('_file_ext'))));
    }

    my $accu_key = $self->param('accu_key');

    my @initial_input_files = ();
    if($self->param('direct_accu_access')) {
      @initial_input_files = @{$self->direct_accu_access($accu_key)};
    } elsif($self->param('merge_star_tissues')) {
      my $files = $self->param('tissue_data')->{$sample_name};
      @initial_input_files = @{$files};
      say "Found ".scalar(@initial_input_files)." files for ".$sample_name;
    } else {
      unless($self->param($accu_key)) {
        $self->warning('You did not have input files for '.$self->analysis->logic_name);
        $self->input_job->autoflow(0);
        $self->complete_early('There are no files to process');
      }
      @initial_input_files = @{$self->param($accu_key)};
    }

    my @processed_input_files = ();
    foreach my $input_file (@initial_input_files) {
      say "Input file: ".$input_file;
      if($input_file) {
        push(@processed_input_files,$input_file);
      }
    }

    if (scalar(@processed_input_files) == 0) {
        $self->warning('You did not have input files for '.$self->analysis->logic_name);
        $self->input_job->autoflow(0);
        $self->complete_early('There are no files to process');
    }

    elsif (scalar(@processed_input_files) == 1 and $self->param('options') !~ /-b /) {
        # In samtools merge you can specify a file with a list of files using -b
        # In other cases I just want to push the filename but I don't need to run the BAM merge
        # First pushing the filename
        my $abs_filename = $processed_input_files[0];
        if (-e File::Spec->catfile($self->param('input_dir'), $abs_filename)) {
            $abs_filename = File::Spec->catfile($self->param('input_dir'), $abs_filename);
        }
        $self->throw($abs_filename.' is not an absolute path!') unless (File::Spec->file_name_is_absolute($abs_filename));
        if ($self->param('rename_file')) {
          my $index_ext = '.'.$self->param('_index_ext');
          if (!move($abs_filename, $self->param('alignment_bam_file'))) {
             $self->throw("Could not rename file $abs_filename to ".$self->param('alignment_bam_file'));
	  }
          if (!move($abs_filename.$index_ext, $self->param('alignment_bam_file').$index_ext)) {
            $self->throw("Could not rename file $abs_filename$index_ext to ".$self->param('alignment_bam_file').$index_ext);
	  }
          $abs_filename = $self->param('alignment_bam_file');
        }
        if ($self->param('store_datafile')) {
          $self->store_filename_into_datafile;
        }
        $self->dataflow_output_id({filename => $abs_filename}, $self->param('_branch_to_flow_to'));
        # Finally tell Hive that we've finished processing
        $self->complete_early('There is only one file to process');
    }
    if ($self->param_is_defined('picard_lib')) {
        $self->require_module('Bio::EnsEMBL::Analysis::Runnable::PicardMerge');
        $self->runnable(Bio::EnsEMBL::Analysis::Runnable::PicardMerge->new(
            -program => $self->param('java') || 'java',
            -java_options => $self->param('java_options'),
            -lib => $self->param('picard_lib'),
            -options => $self->param('options'),
            -analysis => $self->analysis,
            -output_file => $self->param('alignment_bam_file'),
            -input_files => \@processed_input_files,
            -use_threading => $self->param('use_threading'),
            -samtools => $self->param('samtools') || 'samtools',
            ));
    }
    else {
        $self->require_module('Bio::EnsEMBL::Analysis::Runnable::SamtoolsMerge');
        $self->runnable(Bio::EnsEMBL::Analysis::Runnable::SamtoolsMerge->new(
            -program => $self->param('samtools') || 'samtools',
            -options => $self->param('options'),
            -analysis => $self->analysis,
            -output_file => $self->param('alignment_bam_file'),
            -input_files => \@processed_input_files,
            -use_threading => $self->param('use_threading'),
            ));
    }
}


=head2 run

 Arg [1]    : None
 Description: Merge the files and check that the merge was successful
 Returntype : None
 Exceptions : None

=cut

sub run {
    my ($self) = @_;

    $self->dbc->disconnect_if_idle() if ($self->param('disconnect_jobs'));
    foreach my $runnable (@{$self->runnable}) {
        $runnable->run;
        $runnable->check_output_file;
    }
    $self->output([$self->param('alignment_bam_file')]);
}


=head2 write_output

 Arg [1]    : None
 Description: Dataflow the name of the merged BAM file on branch 1 with 'filename'
 Returntype : None
 Exceptions : None

=cut

sub write_output {
    my ($self) = @_;

    if ($self->param('store_datafile')) {
      $self->store_filename_into_datafile;
    }
    $self->dataflow_output_id({filename => $self->output->[0]}, $self->param('_branch_to_flow_to')); 
}


=head2 store_filename_into_datafile

 Arg [1]    : None
 Description: It uses 'species', 'sample_name' or merged to create a logic_name
              such as chicken_bwa_brain, store the analysis in the 'target_db' if
              it does not exists then store the filename in the datafile table
              If 'logic_name' is specified in the parameters, the value is used
 Returntype : None
 Exceptions : None

=cut

sub store_filename_into_datafile {
  my ($self) = @_;

  my $db = $self->hrdb_get_con('target_db');
  $db->dbc->disconnect_when_inactive(0);
  my $analysis_adaptor = $db->get_AnalysisAdaptor;
  my $analysis = $analysis_adaptor->fetch_by_logic_name($self->analysis->logic_name);
  if (!$analysis) {
    $analysis_adaptor->store($self->analysis);
    $analysis = $self->analysis;
  }
  my @coord_systems = sort {$a->rank <=> $b->rank} @{$db->get_CoordSystemAdaptor->fetch_all_by_version($self->param('assembly_name'))};
  my $datafile = Bio::EnsEMBL::DataFile->new();
  $datafile->analysis($analysis);
  $datafile->name(basename($self->param('alignment_bam_file'), '.'.$self->param('_file_ext')));
  $datafile->file_type('BAMCOV');
  $datafile->version_lock(0);
  $datafile->absolute(0);
  $datafile->coord_system($coord_systems[0]);
  $db->get_DataFileAdaptor->store($datafile);
}


sub direct_accu_access {
  my ($self,$accu_key) = @_;

  my $filenames = [];
  my $table_adaptor = $self->db->get_NakedTableAdaptor;
  $table_adaptor->table_name('accu');

  my $results = $table_adaptor->fetch_all();
  foreach my $result (@$results) {
    my $struct_name = $result->{'struct_name'};
    if($struct_name eq $accu_key) {
      my $filename = $result->{'value'};
      $filename =~ s/\"//g;
      push(@{$filenames},$filename);
    }
  }
  return($filenames);
}

1;
