#!/usr/bin/env perl

## merge gene feature if they have CDSs that overlap
# 2015-07

use Carp;
use strict;
use Getopt::Long;
use Data::Dumper;
use Pod::Usage;
use List::MoreUtils qw(uniq);
use BILS::Handler::GXFhandler qw(:Ok);
use BILS::Handler::GFF3handler qw(:Ok);
use Bio::Tools::GFF;

my $usage = qq{
########################################################
# BILS 2015 - Sweden                                   #  
# jacques.dainat\@bils.se                               #
# Please cite BILS (www.bils.se) when using this tool. #
########################################################
};

my $outfile = undef;
my $ref = undef;
my $help= 0;

if ( !GetOptions(
    "help|h" => \$help,
    "f|file|gff3|gff=s" => \$ref,
    "output|outfile|out|o=s" => \$outfile))

{
    pod2usage( { -message => 'Failed to parse command line',
                 -verbose => 1,
                 -exitval => 1 } );
}

# Print Help and exit
if ($help) {
    pod2usage( { -verbose => 2,
                 -exitval => 0,
                 -message => "$usage\n" } );
}
 
if ( ! (defined($ref)) ){
    pod2usage( {
           -message => "\nAt least 1 parameters is mandatory:\n".
           "$usage\n",
           -verbose => 0,
           -exitval => 2 } );
}

######################
# Manage output file #
my $gffout;
if ($outfile) {
  $outfile=~ s/.gff//g;
open(my $fh, '>', $outfile.".gff") or die "Could not open file '$outfile' $!";
  $gffout= Bio::Tools::GFF->new(-fh => $fh, -gff_version => 3 );
}
else{
  $gffout = Bio::Tools::GFF->new(-fh => \*STDOUT, -gff_version => 3);
}

#####################################
# END Manage Ouput Directory / File #
#####################################
my $error_found=undef;
### Parse GFF input #
print ("Parse file $ref\n");
my ($hash_omniscient, $hash_mRNAGeneLink) = BILS::Handler::GFF3handler->slurp_gff3_file_JD($ref);
print ("$ref file parsed\n");

# sort by seq id
my %hash_sortBySeq;
foreach my $tag_level1 (keys %{$hash_omniscient->{'level1'}}){
  foreach my $level1_id (keys %{$hash_omniscient->{'level1'}{$tag_level1}}){
    if (exists_keys($hash_omniscient, ('level2','mrna',$level1_id)) ){ # check if they have mRNA avoiding autovivifcation
      my @mrna_values = $hash_omniscient->{'level2'}{'mrna'}{$level1_id}[0]->get_tag_values('ID');
      my $mrna_id = shift @mrna_values;
      if (exists_keys($hash_omniscient, ('level3','cds',lc($mrna_id))) ){ # check if they have cds avoiding autovivification. Allow to skip tRNA.
        my $position=$hash_omniscient->{'level1'}{$tag_level1}{$level1_id}->seq_id."".$hash_omniscient->{'level1'}{$tag_level1}{$level1_id}->strand;
        push (@{$hash_sortBySeq{$tag_level1}{$position}}, $hash_omniscient->{'level1'}{$tag_level1}{$level1_id});
      }
    }
  }
}

my $total_overlap=0;
#find overlap
my %feature_studied;
foreach my $tag (keys %hash_sortBySeq){ # loop over all the feature level1
  
  foreach my $seqid (keys %{$hash_sortBySeq{$tag}}){
    
    foreach my $gene_feature ( @{$hash_sortBySeq{$tag}{$seqid}}){
     my @values = $gene_feature->get_tag_values('ID');
     my $gene_id = shift @values;
     $feature_studied{$gene_id}++;    
      my @ListOverlapingGene=();     
      my $nb_feat_overlap=0;
      my ($start1,$end1) = get_longest_cds_start_end($hash_omniscient,$gene_id); # look at CDS because we want only ioverlapinng CDS

      foreach my $gene_feature2 ( @{$hash_sortBySeq{$tag}{$seqid}}){ # loop over all the level1 feature except the one we are already focusing on
        my @values2 = $gene_feature2->get_tag_values('ID');
        my $gene_id2 = shift @values2;
       
        if(! exists($feature_studied{$gene_id2}) ){ #we compare different feature
          my ($start2,$end2) = get_longest_cds_start_end($hash_omniscient,$gene_id2); # look at CDS becaus ewe want only ioverlapinng CDS

          if( ($start2 <= $end1) and ($end2 >= $start1) ){ #feature overlap considering extrem start and extrem stop. It's just to optimise the next step. Avoid to do the next step every time. So at the end, that test (current one) could be removed
           
            #now check at each CDS feature independently
            if (two_features_overlap($hash_omniscient,$gene_id, $gene_id2)){
              print "These two features overlap without same id ! :\n".$gene_feature->gff_string."\n".$gene_feature2->gff_string."\n";
              $error_found="yes";
              $nb_feat_overlap++;
              $total_overlap++;
              $feature_studied{$gene_id2}++;  
              push(@ListOverlapingGene, $gene_feature2);
            }
          }
        }
      }

      # Now manage name if some feature overlap
      if( $nb_feat_overlap > 0){
        push(@ListOverlapingGene, $gene_feature);
        print "$nb_feat_overlap overlapping feature found ! We will treat them now:\n";
        my ($reference_feature, $ListToRemove)=take_one_as_reference(\@ListOverlapingGene);
        print "We decided to keep that one: ".$reference_feature->gff_string."\n";

        my $gene_id_ref  = $reference_feature->_tag_value('ID');

        #change level2 parent for feature of level2 that have a feature of level1 in $ListToRemove list
        foreach my $featureToRemove (@$ListToRemove){

          my @values_to_remove = $featureToRemove->get_tag_values('ID');
          my $gene_id_to_remove = lc(shift @values_to_remove);

          foreach my $tag_level2 (keys %{$hash_omniscient->{'level2'}}){

            if (exists_keys($hash_omniscient, ('level2',$tag_level2,$gene_id_to_remove)) ){ # check if they have cds avoiding autovivification.
      
              my @list_tmp_features = @{$hash_omniscient->{'level2'}{$tag_level2}{$gene_id_to_remove}}; # As we will remove element of the list we cannot loop over it directly, we have to save the list in a temporary list;
              foreach my $level2_feature (@list_tmp_features){ #replace Parent of each feature level2 by the new level1 reference 
                # Change parent feature
                create_or_replace_tag($level2_feature,'Parent',$gene_id_ref);
                
                #add it in other list
                push (@{$hash_omniscient->{'level2'}{$tag_level2}{lc($gene_id_ref)}},$level2_feature);
                
                #remove mRNA from list <= not mandatory
                my @mrna_values_to_remove = $level2_feature->get_tag_values('ID');
                my $mrna_id_to_remove = lc(shift @mrna_values_to_remove);

                my @tag_list=('all');
                my @id_list=($gene_id_to_remove);my @id_list2=($mrna_id_to_remove);

                remove_element_from_omniscient(\@id_list, \@id_list2, $hash_omniscient, 'level2', 'false', \@tag_list);

              }
            }  
          }
          foreach my $tag_level1 (keys %{$hash_omniscient->{'level1'}}){ # remove the old feature level1 now
              delete $hash_omniscient->{'level1'}{$tag_level1}{$gene_id_to_remove}; # delete level1
          }
        } #END FEATURE TO HANDLE
        ###
        # check end and start of the new feature
        my $gene_id=lc($reference_feature->_tag_value('ID'));
        check_gene_positions($hash_omniscient, $gene_id);
        print "\n\n";
      }
    }
  }
}

if(! $error_found){
  print "No gene overlaping with different name has been found !\n";
}else{
  print "$total_overlap genes overlap\n";
}
print_omniscient($hash_omniscient, $gffout); #print gene modified
print "END\n";

#######################################################################################################################
        ####################
         #     METHODS    #
          ################
           ##############
            ############
             ##########
              ########
               ######
                ####
                 ##

sub take_one_as_reference{
  my ($ListOverlapingGene)=@_;

  my $reference_feature=undef;
  foreach my $feature (@$ListOverlapingGene){
    # case of the crow project (We developped this script for this project first of all)
    if ($feature->has_tag('oId')){ #check again that part please
      if ($feature->has_tag('Name')){
        my @values_ref = $feature->get_tag_values('Name');
        my $id = shift @values_ref;
        if ($id !~ /"{2,}?/){ # If there is a name
          $reference_feature=$feature;last;
        }
      }
      if(! $reference_feature){
        $reference_feature=$feature;
      }
    }
    #fix_fusion case
    if ($feature->has_tag('ID')){
      my $id_current= $feature->_tag_value('ID');
      if($id_current =~ /^[^new]/){
        $reference_feature=$feature;
        if ($feature->has_tag('Name')){
          my $name_current= $feature->_tag_value('Name');
          if(($name_current =~ /^[^new]/) and (! index($name_current, 'NO NAME ASSIGNED') != -1 )) {
            $reference_feature=$feature;last;
          }
          elsif($name_current =~ /^[^new]/){
            $reference_feature=$feature;
          }
          else{$reference_feature=undef;} #If "NO NAME ASSIGNED" we don't keep it to try another
        }
      }
    }
  }

  # so get it randomly 
  if(! $reference_feature){     
    $reference_feature=shift(@$ListOverlapingGene);
  }
  else{
    my @values_ref = $reference_feature->get_tag_values('ID');
    my $id_ref = shift @values_ref;
    my @new_list;
    foreach my $feature (@$ListOverlapingGene){
      my @values = $feature->get_tag_values('ID');
      my $id = shift @values;
      if($id_ref ne $id){
        push(@new_list, $feature);
      }
    }
    $ListOverlapingGene=\@new_list;
  }

return $reference_feature, $ListOverlapingGene;
}

sub get_longest_cds_start_end{
  my  ($hash_omniscient,$gene_id)=@_;
  my $resu_start=100000000000;
  my $resu_end=0;

  #check full CDS for each mRNA
  foreach my $mrna_feature (@{$hash_omniscient->{'level2'}{'mrna'}{lc($gene_id)}}){
    my @values = $mrna_feature->get_tag_values('ID');
    my $mrna_id = shift @values;
    my $extrem_start=100000000000;
    my $extrem_end=0;
   
    #check all cds pieces
    foreach my $cds_feature (@{$hash_omniscient->{'level3'}{'cds'}{lc($mrna_id)}}){
      if ($cds_feature->start < $extrem_start){
        $extrem_start=$cds_feature->start;
      }
      if($cds_feature->end > $extrem_end){
              $extrem_end=$cds_feature->end ;
      }
    }
    
    if($extrem_start < $resu_start){
        $resu_start=$extrem_start;
    }
    if($extrem_end > $resu_end){
      $resu_end=$extrem_end;
    }
  }
  return $resu_start,$resu_end;
}

#Check if two genes have at least one mRNA isoform which overlap at cds level.
sub two_features_overlap{
  my  ($hash_omniscient,$gene_id, $gene_id2)=@_;
  my $resu=undef;

  #check full CDS for each mRNA
  foreach my $mrna_feature (@{$hash_omniscient->{'level2'}{'mrna'}{lc($gene_id)}}){
    foreach my $mrna_feature2 (@{$hash_omniscient->{'level2'}{'mrna'}{lc($gene_id2)}}){

      my @values1 = $mrna_feature->get_tag_values('ID');
      my $mrna_id1 = shift @values1;

      my @values2 = $mrna_feature2->get_tag_values('ID');
      my $mrna_id2 = shift @values2;
   
      #check all cds pieces
      foreach my $cds_feature1 (@{$hash_omniscient->{'level3'}{'cds'}{lc($mrna_id1)}}){
        foreach my $cds_feature2 (@{$hash_omniscient->{'level3'}{'cds'}{lc($mrna_id2)}}){
          
          if(($cds_feature2->start <= $cds_feature1->end) and ($cds_feature2->end >= $cds_feature1->start )){ # they overlap
            $resu="yes";last;
          }
        }
        if($resu){last;}
      }
      if($resu){last;}
    }
    if($resu){last;}  
  }
  return $resu;
}

__END__


=head1 NAME

gff_checkOverlapingGeneFeatures.pl - Check a gff3 annotation file to
find cases where differents gene features have CDS that overlap. In this case the gene features will be merged in only one. 
One gene is choosen as reference, and the mRNA from the other gene will be linked to it. So, it creates isoforms.

=head1 SYNOPSIS

    ./gff_checkOverlapingGeneFeatures.pl -f infile  [-o outfile]
    ./gff_checkOverlapingGeneFeatures.pl --help

=head1 OPTIONS

=over 8

=item B<-f>, B<--file>, B<--gff3> or B<--gff>

Input GFF3 file.

=item B<-o>, B<--out>, B<--output> or B<--outfile>

Output file. If none given, will be display in standard output.

=item B<--help> or B<-h>

Display this helpful text.

=back

=cut
