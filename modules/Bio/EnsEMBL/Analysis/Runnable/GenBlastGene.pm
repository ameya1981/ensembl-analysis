# Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
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

=head1 NAME

Bio::EnsEMBL::Analysis::Runnable::GenBlast

=head1 SYNOPSIS

my $runnable = Bio::EnsEMBL::Analysis::Runnable::GenBlast->new(
      -query => $slice,
      -program => 'genblast',
     );
  $runnable->run;
  my @predictions = @{$runnable->output};


=head1 DESCRIPTION

Wrapper to run the genBlast gene prediction program that is based on
protein homology (http://genome.sfu.ca/genblast/) against a set of
proteins.  The resulting output file is parsed into prediction
transcripts.

=head1 CONTACT

Post questions to the Ensembl development list: http://lists.ensembl.org/mailman/listinfo/dev

=cut

package Bio::EnsEMBL::Analysis::Runnable::GenBlastGene;

use strict;
use warnings;
use feature 'say';


use File::Basename;

use Bio::EnsEMBL::Analysis::Tools::GeneBuildUtils::TranscriptUtils qw(calculate_exon_phases);

use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::EnsEMBL::Utils::Argument qw( rearrange );

use parent('Bio::EnsEMBL::Analysis::Runnable');

=head2 new

  Arg [1]   : Bio::EnsEMBL::Analysis::Runnable::GenBlast
  Function  : create a Bio::EnsEMBL::Analysis::Runnable::GenBlast runnable
  Returntype: Bio::EnsEMBL::Analysis::Runnable::GenBlast
  Exceptions: none
  Example   :

=cut



sub new {
  my ($class,@args) = @_;
  my $self = $class->SUPER::new(@args);

  my ($database,$ref_slices,$genblast_program,$uniprot_index) = rearrange([qw(DATABASE
                                                                              REFSLICES
                                                                              GENBLAST_PROGRAM
                                                                              UNIPROT_INDEX)], @args);
  $self->database($database) if defined $database;
  $self->genome_slices($ref_slices) if defined $ref_slices;
  # Allows the specification of exonerate or genewise instead of genblastg. Will default to genblastg if undef
  $self->genblast_program($genblast_program) if defined $genblast_program;
  # Allow loading of an index file that has the following structure: P30378:sp:2:1:primates_pe12
  # (accession:database:pe_level:sequence_version:group)
  $self->uniprot_index($uniprot_index) if defined $uniprot_index;

  throw("You must supply a database") if not $self->database;
  throw("You must supply a query") if not $self->query;
  throw("You must supply a hash of reference slices") if not $self->genome_slices;

  return $self;
}

############################################################
#
# Analysis methods
#
############################################################

=head2 run

  Arg [1]   : Bio::EnsEMBL::Analysis::Runnable
  Arg [2]   : string, directory
  Function  : a generic run method. This checks the directory specifed
  to run it, write the query sequence to file, marks the query sequence
  file and results file for deletion, runs the analysis parses the 
  results and deletes any files
  Returntype: 1
  Exceptions: throws if no query sequence is specified
  Example   :

=cut


sub run{
  my ($self, $dir) = @_;
  $self->workdir($dir) if($dir);
  throw("Can't run ".$self." without a query sequence") 
    unless($self->query);
  $self->checkdir();
  $self->run_analysis();
  $self->parse_results;
  return 1;
}



=head2 run_analysis

  Arg [1]   : Bio::EnsEMBL::Analysis::Runnable::BaseAbInitio
  Arg [2]   : string, program name
  Function  : create and open a commandline for one
  of the ab initio gene finding programs
  Returntype: none
  Exceptions: throws if the program in not executable or the system
  command fails to execute
  Example   : 

=cut

sub run_analysis{
  my ($self, $program) = @_;
  if(!$program){
    $program = $self->program;
  }

  throw($program." is not executable GenBlast::run_analysis ") 
    unless($program && -x $program);

  my $workdir = "/tmp";

  # set up environment variables
  # we want the path of the program_file
  my $dir = dirname($program);
  $ENV{GBLAST_PATH} = $dir;
  $ENV{path} = "" if (!defined $ENV{path});
  $ENV{path} = "(".$ENV{path}.":".$dir.")";

  # link to alignscore.txt if not already linked
  chdir $workdir;
  my $ln_cmd = "ln -s ".$dir."/alignscore.txt alignscore.txt";
  my $value = system($ln_cmd) unless (-e "alignscore.txt"); 

  # genBlast sticks "_1.1c_2.3_s1_0_16_1" on the end of the output
  # file for some reason - it will probably change in future
  # versions of genBlast.  
  my $outfile_suffix = "_1.1c_2.3_s1_0_16_1";
  my $outfile_glob_prefix = $self->query . $outfile_suffix;

  # if there are old files around, need to get rid of them
  foreach my $oldfile (glob("${outfile_glob_prefix}*")) {
    unlink $oldfile;
  }

  my $genblast_program = $self->genblast_program;
  unless($genblast_program) {
    $genblast_program = "genblastg";
  }
  my $command = $program .
  ' -p '.$genblast_program.
  ' -q '.$self->query.
  ' -t '.$self->database.
  ' -o '.$self->query.
  ' -cdna -pro   '.$self->options;

  $self->resultsfile($self->query. $outfile_suffix. ".gff");

  my $return = system($command);

  unless($return == 0) {
    throw("genblast returned a non-zero exit code (".$return."). Commandline used:\n".$command);
  }

  foreach my $file (glob("${outfile_glob_prefix}*")) {
    $self->files_to_delete($file);
  }
}

=head2 parse_results

  Arg [1]   : Bio::EnsEMBL::Analysis::Runnable::Genscan
  Arg [2]   : string, resultsfile name
  Function  : parse the results file into prediction exons then
  collate them into prediction transcripts and calculate their
  phases
  Returntype: none 
  Exceptions: throws if cant open or close results file or the parsing
  doesnt work
  Example   : 

=cut


sub parse_results{
  my ($self, $results) = @_;

 if(!$results){
    $results = $self->resultsfile;
  }

  open(OUT, "<".$results) or throw("FAILED to open ".$results."\nGenBlast:parse_results");
  my (%transcripts, @transcripts);

  LINE:while(<OUT>){
    chomp;
    if(/^#/){
      next LINE;
    }
    # ##gff-version 3
    # ##sequence-region       1524908_group1  1       6746
    # 1524908 genBlastG       transcript      72538   75301   81.7114 +       .       ID=2RSSE.1-R1-1-A1;Name=2RSSE.1
    # 1524908 genBlastG       coding_exon     72538   72623   .       +       .       ID=2RSSE.1-R1-1-A1-E1;Parent=2RSSE.1-R1-1-A1
    # 1524908 genBlastG       coding_exon     73276   73336   .       +       .       ID=2RSSE.1-R1-1-A1-E2;Parent=2RSSE.1-R1-1-A1
    # 1524908 genBlastG       coding_exon     73694   73855   .       +       .       ID=2RSSE.1-R1-1-A1-E3;Parent=2RSSE.1-R1-1-A1
    # 1524908 genBlastG       coding_exon     74260   74372   .       +       .       ID=2RSSE.1-R1-1-A1-E4;Parent=2RSSE.1-R1-1-A1
    # 1524908 genBlastG       coding_exon     74629   74800   .       +       .       ID=2RSSE.1-R1-1-A1-E5;Parent=2RSSE.1-R1-1-A1
    # 1524908 genBlastG       coding_exon     75092   75301   .       +       .       ID=2RSSE.1-R1-1-A1-E6;Parent=2RSSE.1-R1-1-A1

    if(/transcript|coding_exon/i){
      my @elements = split;
      if(@elements != 9){
        throw("Can't parse ".$_." splits into wrong number of elements ".
              "GenBlast:parse_results");
      }
      my ($chromosome, $type, $start, $end, $score, $strand, $other) =  @elements[0, 2, 3, 4, 5, 6, 8];

      if ($type eq 'transcript') {
        my ($group, $hitname) = ($other =~ /ID=(\S+?);Name=(\S+)/);
        $group =~ /^$hitname\-R(\d+)\-/;
        my $rank = $1;
        $transcripts{$group}->{score} = $score;
        $transcripts{$group}->{hitname} = $hitname;
        $transcripts{$group}->{rank} = $rank;
      } elsif ($type eq 'coding_exon') {
        my ($group) = ($other =~ /Parent=(\S+)/);
        if (not exists $self->genome_slices->{$chromosome}) {
          throw("No slice supplied to runnable with for $chromosome");
        }

        my $exon = Bio::EnsEMBL::Exon->new(-start => $start,
                                           -end   => $end,
                                           -strand => $strand eq '-' ? -1 : 1,
                                           -analysis => $self->analysis,
                                           -slice => $self->genome_slices->{$chromosome});
        push @{$transcripts{$group}->{exons}}, $exon;
      }
    }
  }
  close(OUT) or throw("FAILED to close ".$results.
                      "GenBlast:parse_results");

  foreach my $tid (keys %transcripts) {
    # Hardcoding to select only to top ranked model for the moment. Like exonerate best in genome. Will allow for
    # the rank to be selected in future
    unless($transcripts{$tid}->{rank} == 1) {
      say "Skipping output of transcript '".$transcripts{$tid}->{hitname}."' due to rank (".
           $transcripts{$tid}->{rank}.")";
      next;
    }

    my @exons = sort { $a->start <=> $b->start } @{$transcripts{$tid}->{exons}};

    my $biotype;
    if($self->uniprot_index) {
      $biotype = $self->build_biotype($self->uniprot_index,$transcripts{$tid}->{hitname});
    }

    my $tran = Bio::EnsEMBL::Transcript->new(-exons => \@exons,
                                             -slice => $exons[0]->slice,
                                             -analysis => $self->analysis,
                                             -stable_id => $transcripts{$tid}->{hitname});

    $tran->biotype($biotype);

    # Reverse the exons for negative strand to calc the translations
    my $strand = $exons[0]->strand;
    if($strand == -1) {
      @exons = sort { $b->start <=> $a->start } @{$transcripts{$tid}->{exons}};
    }

    my $start_exon = $exons[0];
    my $end_exon = $exons[scalar(@exons)-1];
    my $translation = Bio::EnsEMBL::Translation->new();
    $translation->start_Exon($start_exon);
    $translation->start(1);
    $translation->end_Exon($end_exon);
    $translation->end($end_exon->length());
    $tran->translation($translation);

    # Set the phases
    calculate_exon_phases($tran, 0);
    push @transcripts, $tran;

#    my $pep = $tran->translate->seq;
#    if ($pep =~ /\*/) {
#      printf STDERR "Bad translation for $tid : $pep\n";
#    }
  }

  $self->clean_output;
  $self->output(\@transcripts);

}



sub build_biotype {
  my ($self,$index_path,$accession) = @_;

  unless(-e $index_path) {
    throw("You specified an index file that doesn't exist. Path:\n".$index_path);
  }

  my $cmd = "grep '^".$accession."\:' $index_path";
  my $result = `$cmd`;
  chomp $result;

  unless($result) {
    throw("You specified an index file to use but the accession wasn't found in it. Commandline used:\n".$cmd);
  }

  my @result_array = split(':',$result);
  my $group = $result_array[4];
  my $database = $result_array[1];
  my $biotype = $group."_".$database;

  if($biotype eq '_') {
    throw("Found a malformaed biotype based on parsing index. The accession in question was:\n".$accession);
  }

  return($biotype);

}

sub uniprot_index {
  my ($self,$val) = @_;
  if($val) {
    $self->{_uniprot_index} = $val;
  }
  return($self->{_uniprot_index});
}

############################################################
#
# get/set methods
#
############################################################

=head2 query

    Title   :   query
    Usage   :   $self->query($seq)
    Function:   Get/set method for query.  If set with a Bio::Seq object it
                will get written to the local tmp directory
    Returns :   filename
    Args    :   Bio::PrimarySeqI, or filename

=cut

sub query {
  my ($self, $val) = @_;

  if (defined $val) {
    if (not ref($val)) {
      throw("[$val] : file does not exist\n") unless -e $val;
    } elsif (not $val->isa("Bio::PrimarySeqI")) {
      throw("[$val] is neither a Bio::Seq not a file");
    }
    $self->{_query} = $val;
  }

  return $self->{_query}
}


=head2 database

    Title   :   database
    Usage   :   $self->database($seq)
    Function:   Get/set method for database.  If set with a Bio::Seq object it
                will get written to the local tmp directory
    Returns :   filename
    Args    :   Bio::PrimarySeqI, or filename

=cut

sub database {
  my ($self, $val) = @_;

  if (defined $val) {
    if (not ref($val)) {
      throw("[$val] : file does not exist\n") unless -e $val;
    } else {
      if (ref($val) eq 'ARRAY') {
        foreach my $el (@$val) {
          throw("All elements of given database array should be Bio::PrimarySeqs")
        }
      } elsif (not $val->isa("Bio::PrimarySeq")) {
        throw("[$val] is neither a file nor array of Bio::Seq");
      } else {
        $val = [$val];
      }
    }
    $self->{_database} = $val;
  }

  return $self->{_database};
}


sub genome_slices {
  my ($self, $val) = @_;

  if (defined $val) {
    $self->{_genome_slices} = $val;
  }

  return $self->{_genome_slices}
}

sub genblast_program {
  my ($self, $val) = @_;

  if (defined $val) {
    $self->{_genblast_program} = $val;
  }

  return $self->{_genblast_program}
}

1;