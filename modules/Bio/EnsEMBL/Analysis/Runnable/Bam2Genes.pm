=head1 LICENSE

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

=head1 CONTACT

Please email comments or questions to the public Ensembl
developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

Questions may also be sent to the Ensembl help desk at
<http://www.ensembl.org/Help/Contact>.

=cut

=head1 NAME

Bio::EnsEMBL::Analysis::Runnable::BWA

=head1 SYNOPSIS

my $runnable =
Bio::EnsEMBL::Analysis::Runnable::BWA->new();

$runnable->run;
my @results = $runnable->output;

=head1 DESCRIPTION

This module uses BWA to align fastq to a genomic sequence

=head1 METHODS

=cut


package Bio::EnsEMBL::Analysis::Runnable::Bam2Genes;

use warnings ;
use vars qw(@ISA);
use strict;

use Bio::EnsEMBL::Analysis::Runnable;
use Bio::EnsEMBL::Utils::Argument qw( rearrange );
use Bio::EnsEMBL::DnaDnaAlignFeature;
use Bio::EnsEMBL::Transcript;
use Bio::EnsEMBL::Analysis::Tools::GeneBuildUtils::TranscriptUtils qw(convert_to_genes);
use Bio::EnsEMBL::Analysis::Tools::GeneBuildUtils::ExonUtils qw(create_Exon);

@ISA = qw(Bio::EnsEMBL::Analysis::Runnable);

sub new {
    my ( $class, @args ) = @_;
    my $self = $class->SUPER::new(@args);
    my ($min_length, $min_exons, $paired, $max_intron_length, $min_single_exon_length, $min_span, $exon_clusters) =
        rearrange([qw (MIN_LENGTH MIN_EXONS PAIRED MAX_INTRON_LENGTH MIN_SINGLE_EXON_LENGTH MIN_SPAN EXON_CLUSTERS)],@args);
    $self->exon_cluster($exon_clusters);
    $self->min_exons($min_exons);
    $self->min_length($min_length);
    $self->paired($paired);
    $self->max_intron_length($max_intron_length);
    $self->min_single_exon_length($min_single_exon_length);
    $self->min_span($min_span);

    return $self;
}

sub run {
    my $self = shift;

    my @genes;
    my $exon_clusters  = $self->exon_cluster;
    my $transcripts = $self->process_exon_clusters($exon_clusters);
    if ( $transcripts ) {
        # Now we have collapsed our reads we need to make sure we keep the connections between
        # them so we can make our fake transcripts
        print STDERR "Found " . scalar(@$transcripts) . " transcripts \n";
        foreach my $transcript ( @$transcripts ) {
            #print  STDERR scalar(@$exon_cluster) ." exon clusters\n";
            next unless scalar(@$transcript) > 0;
            # make the dna align feature
            my $padded_exons = $self->pad_exons($transcript);
            if ($padded_exons) {
                my $gene = $self->make_gene($padded_exons);
                my $tran = $gene->get_all_Transcripts->[0];
                print "FILTERING " . $tran->start ." " , $tran->end ." ";
                # Filter models before writing them
                if ( scalar(@{$tran->get_all_Exons}) < $self->min_exons ) {
                    print "Rejecting because of exon count " .  scalar(@{$tran->get_all_Exons}) ."\n";
                    next;
                }
                if (  $tran->length < $self->min_length ){
                    print "Rejecting because of length " . $tran->length ."\n";
                    next;
                }
                if ( scalar(@{$gene->get_all_Exons}) == 1){
                    if ( $tran->length <  $self->min_single_exon_length ){
                        print "Rejecting single exon transcript because of length " . $tran->length ."\n";
                        next;
                    }
                }
                else {
                    # filter span on multiexon genes
                    if( ( $tran->end - $tran->start +1 ) / $tran->length < ($self->min_span) ) {
                        if ( $tran->length <  $self->min_single_exon_length ){
                            print "Rejecting because of span " . ( $tran->end - $tran->start +1 ) / $tran->length ."\n";
                            next;
                        }
                    }
                }
                $gene->analysis($self->analysis);
                $gene->source($self->analysis->logic_name);
                $gene->biotype('rough');
                push(@genes, $gene);
            }
        }
    }
    else {
        print STDERR "No transcripts found for this slice\n";
    }

    $self->output(\@genes);
}

sub process_exon_clusters {
    my ( $self, $exon_clusters ) = @_;

    my $cluster_data = $self->cluster_data;
    my $clean_exon_clusters;
    my @final_exon_clusters;
    my @transcripts;
    my $cluster_hash;
    my $pairs;
    # dont use any reads in the processing only clusters and read names
    print STDERR "Processing ". scalar(keys %{$exon_clusters} ) ." Clusters\n";

    if ( scalar(keys %{$exon_clusters}) == 1 ) {
        # just keep single exon clusters for now - might be useful later
        foreach my $cluster ( values %{$exon_clusters} ) {
            my @transcript;
            push @transcript, $cluster;
            push @transcripts, \@transcript;
        }
        return \@transcripts;
    }

    unless ( $self->paired ) {
        # if we are using unpaired reads then just link clusters separated by <= MAX_INTRON_LENGTH
        my @clusters = sort { $a->start <=> $b->start } values %{$exon_clusters} ;
        my @transcript;
        my @transcripts;
        for ( my $i = 1 ; $i <= $#clusters ; $i++ ) {
            my $left = $clusters[$i-1];
            my $right = $clusters[$i];
            if ( $right->start <= $left->end + $self->max_intron_length ) {
                push @transcript,$left;
                push @transcript,$right if $i == $#clusters;
            } else {
                #copy it before you store it or else you get reference issues
                my @tmp_transcript = @transcript;
                push @transcripts, \@tmp_transcript;
                # empty the array
                @transcript = ();
                pop @transcript;
                push @transcript,$right if $i == $#clusters;
            }
            if ($i == $#clusters ) {
                push @transcripts, \@transcript;
            }
        }
        return \@transcripts;
    }

    # make the exon pairings store them in cluster hash
    foreach my $read ( keys %{$cluster_data} ) {
        my @clusters = keys %{$cluster_data->{$read}};
        my $left_cluster = $exon_clusters->{$clusters[0]}->hseqname;
        for (my $i = 1; $i < @clusters ; $i ++ ) {
            my $right_cluster =  $exon_clusters->{$clusters[$i]}->hseqname;
            $cluster_hash->{$left_cluster}->{$right_cluster} ++
                unless $left_cluster eq $right_cluster;
        }
    }

    # now need to find little clusters sitting in introns that are not connected to the transcript
    # do a reclustering based on which exons are connected to each other
    my @clean_clusters =  keys %$exon_clusters;
    return unless ( scalar(@clean_clusters) > 0) ;

    # put one exon into the first cluster
    my @temp;
    push @temp,  pop(@clean_clusters);
    push @final_exon_clusters, \@temp;
    my $trans_count = 0;
    LOOP:  while ( scalar(@clean_clusters) > 0 ) {
           my $clustered;
           my $final_exon_cluster = $final_exon_clusters[$trans_count];
           foreach my $cluster_num ( @{$final_exon_cluster} ) {
               $clustered = 0;
                # do ANY of our exons join to this exon?
               for ( my $i =0  ; $i <= $#clean_clusters; $i++ )  {
                   my $index = $clean_clusters[$i];
                   # is the current exon attached to any exon in our cluster?
                   if ( $cluster_hash->{$index}->{$cluster_num} or $cluster_hash->{$cluster_num}->{$index}) {
                       push @{$final_exon_cluster}, $index;
                       # chop it out
                       splice(@clean_clusters,$i,1);
                       $i--;
                       $clustered = 1;
                   }
               }
           }
           unless ($clustered) {
               next unless scalar(@clean_clusters) > 0;
               my @temp;
               push @temp,  pop(@clean_clusters);
# start another cluster
               push @final_exon_clusters, \@temp;
               $trans_count++;
           }
       }

# So far we have just dealt with array indecies
# now store the actual features
       foreach my $exon_cluster ( @final_exon_clusters ) {
           my @transcript;
# get a non redundant set of exons
           foreach my $exon ( @$exon_cluster  ) {
               print "Adding exon $exon \n";
               push @transcript, $exon_clusters->{$exon};
           }
           @transcript =   sort { $a->start <=> $b->start} @transcript;
           push @transcripts, \@transcript;
       }
       return \@transcripts;
}


=head2 pad_exons
    Title       :   pad_exons
    Usage       :   $self->($exon_clusters)
    Returns     :   Array ref of Bio::EnsEMBL::Exon
    Args        :   Array ref of Bio::EnsEMBL::Exon
    Description :   Takes an array of Exons, pads them and builds a
                :   DnaAlignFeature from it that represents a transcript
=cut

sub pad_exons {
    my ($self,$exon_cluster_ref) = @_;

    my @padded_exons;
    my @exon_clusters = sort { $a->start <=> $b->start } @$exon_cluster_ref;
    # make a padded exon array
    foreach my $exon ( @exon_clusters ){
        my $padded_exon =  create_Exon
            (
             $exon->start - 20,
             $exon->end + 20 ,
             -1,
             -1,
             -1,
             $exon->analysis,
             undef,
             undef,
             $self->query,
            );
        # dont let it fall of the slice because of padding
        $padded_exon->start(1) if $padded_exon->start <= 0;
        $padded_exon->end($self->query->end)
            if ($padded_exon->end > $self->query->end);

        my $feat = new Bio::EnsEMBL::DnaDnaAlignFeature
            (-slice    => $exon->slice,
             -start    => $padded_exon->start,
             -end      => $padded_exon->end,
             -strand   => -1,
             -hseqname => $exon->display_id,
             -hstart   => 1,
             -hstrand  => 1,
             -hend     => $padded_exon->length,
             -analysis => $exon->analysis,
             -score    => $exon->score,
             -cigar_string => $padded_exon->length.'M');
        my @feats;
        push @feats,$feat;
        $padded_exon->add_supporting_features(@feats);
        push @padded_exons, $padded_exon;
    }

    # dont let adjacent exons overlap
    for ( my $i = 1 ; $i <= $#padded_exons; $i++ ) {
        my $exon =  $padded_exons[$i];
        my $last_exon = $padded_exons[$i-1];
        if ( $last_exon->end >= $exon->start ) {
            # trim the exons so they dont overlap
            my $trim = int(($exon->start - $last_exon->end) /2);
            $last_exon->end(   $last_exon->end  + ($trim) -1 );
            $exon->start( $exon->start - ($trim)+1 );
        }
    }
    return \@padded_exons
}

=head2 make_gene
    Title       :   make_gene
    Usage       :   $self->make_gene($exons)
    Returns     :   Array ref of Bio::EnsEMBL::Gene objects
    Args        :   Array ref of Bio::EnsEMBL::Exon objects
    Description :   Builds gene models from an array of exons
=cut

sub make_gene {
    my ($self,$exon_ref) = @_;
    # we are making reverse strand genes so the exons need to be in the reverse order
    my @exons = sort { $b->start <=>  $a->start } @$exon_ref;
    my $tran =  new Bio::EnsEMBL::Transcript(-EXONS => \@exons);
    $tran->analysis($self->analysis);
    my ($gene) = @{convert_to_genes(($tran),$self->analysis)};
    return $gene;
}

###########################################
# Containers

sub read_count {
    my ($self, $value) = @_;
    if (defined $value ) {
        $self->{'_read_count'} = $value;
    }
    return $self->{'_read_count'};
}

sub cluster_data {
    my ($self, $val) = @_;

    if (defined $val) {
        $self->{_cluster_data} = $val;
    }

    return $self->{_cluster_data};
}

sub exon_cluster {
    my ($self, $value) = @_;
    if (defined $value ) {
        $self->{'_exon_cluster'} = $value;
    }
    return $self->{'_exon_cluster'};
}

sub min_exons {
    my ($self, $value) = @_;
    if (defined $value ) {
        $self->{'_min_exons'} = $value;
    }
    return $self->{'_min_exons'};
}

sub min_length {
    my ($self, $value) = @_;
    if (defined $value ) {
        $self->{'_min_length'} = $value;
    }
    return $self->{'_min_length'};
}

sub paired {
    my ($self, $value) = @_;
    if (defined $value ) {
        $self->{'_paired'} = $value;
    }
    return $self->{'_paired'};
}

sub max_intron_length {
    my ($self, $value) = @_;
    if (defined $value ) {
        $self->{'_max_intron_length'} = $value;
    }
    return $self->{'_max_intron_length'};
}

sub min_single_exon_length {
    my ($self, $value) = @_;
    if (defined $value ) {
        $self->{'_min_single_exon_length'} = $value;
    }
    return $self->{'_min_single_exon_length'};
}

sub min_span {
    my ($self, $value) = @_;
    if (defined $value ) {
        $self->{'_min_span'} = $value;
    }
    return $self->{'_min_span'};
}

1;