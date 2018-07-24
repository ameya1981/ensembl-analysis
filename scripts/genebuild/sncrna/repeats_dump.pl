
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

use strict;
use warnings;

use Bio::EnsEMBL::DBSQL::DBAdaptor;

my ($dbname, $dbhost, $dbport, $dbuser, $working_dir, $logic_name) = @ARGV;

my $db = Bio::EnsEMBL::DBSQL::DBAdaptor->new(
	-DBNAME => $dbname,
  	-HOST => $dbhost,
  	-PORT => $dbport,
  	-USER => $dbuser,
	-DRIVER => 'mysql',
);

# dump repeat features
my $rfa = $db->get_RepeatFeatureAdaptor();
my $fn = $working_dir . "/repeats.bed";
open(FH, '>', $fn) or die "Could not write to $fn";

my $sa = $db->get_SliceAdaptor();
my $slice_name;

foreach my $slice (@{ $sa->fetch_all( 'toplevel') }){
  $slice_name = $slice->seq_region_name();
  foreach my $repeat (@{ $rfa->fetch_all_by_Slice($slice) }){
    my $strand = $repeat->strand() > 0 ? "+" : "-";
    print FH "chr" . $slice_name, "\t",
      $repeat->seq_region_start(), "\t",
      $repeat->seq_region_end(), "\t",
      $strand, "\n";
  }
}

close(FH) or die "Could not close $fn";

