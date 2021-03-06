#Package- merge VCF files and run pileup for SNP and exonerate for indels

package Sanger::CGP::Vaf::Process::Variant; 
##########LICENCE############################################################
# Copyright (c) 2016 Genome Research Ltd.
# 
# Author: Cancer Genome Project cgpit@sanger.ac.uk
# 
# This file is part of cgpVAF.
# 
# cgpVAF is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation; either version 3 of the License, or (at your option) any
# later version.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.
##########LICENCE##############################################################

BEGIN {
  $SIG{__WARN__} = sub {warn $_[0] unless(( $_[0] =~ m/^Subroutine Tabix.* redefined/) .
   ($_[0] =~ m/^Odd number of elements in hash assignment/) || ($_[0] =~m/^Use of uninitialized value \$gtype/) || ($_[0] =~ m/^Use of uninitialized value \$buf/)|| ($_[0] =~ m/symlink exists/) || ($_[0] =~ m/gzip: stdout: Broken pipe/) )};

};

$main::SQL_LIB_LOC = '.'; # this suppresses warnings about uninitialised values
use strict;
use Tabix;
use Vcf;
use Data::Dumper;
use English;
use FindBin qw($Bin);
use List::Util qw(first reduce max min);
use warnings FATAL => 'all';
use Capture::Tiny qw(:all);

use Math::Round qw(round);
use Bio::DB::Sam;
use Bio::DB::Sam::Constants;

use Sanger::CGP::Vaf::VafConstants;

use Log::Log4perl;
Log::Log4perl->init("$Bin/../config/log4perl.vaf.conf");
my $log = Log::Log4perl->get_logger(__PACKAGE__);

use base qw(Sanger::CGP::Vaf::Process::AbstractVariant);

1; 


sub _localInit {
	my $self=shift;
	
} 

=head2 formatVarinat
get hash containing location specific information
Inputs
=over 2
=back
=cut

sub formatVarinat {
  my ($self) = @_;
  my $insertion_flag=undef;
  my $del_flag=undef;
  my $g_pu=undef; 
  my ($chr,$start,$ref,$alt)=(split ':', $self->getLocation)[0,1,2,3];
  my $end=$start;
  #different for indels...
  if($self->getVarType eq 'indel') {
		# if this is an insertion event no change in ref segment
		# if deletion event add length of del bases to start position to get end of deletion 
		# data for this analysis is not taken from info field to accomodate the custom bed locations...
		$insertion_flag=1;
		$del_flag=0;
		if(defined $ref && length($ref) > 1 ) { # if deletion 
			$end=$start+(length($ref)); # no need to do +1 ref base already included in the deletion seq
			$insertion_flag=0;
			$del_flag=1;
		}
		#case of --> complex indel
		if(defined $ref && length($alt) > 1) { $insertion_flag=1;}
  }

	$g_pu={'chr'=>$chr, 
				'start' => $start, 
				'end' => $end, 
				'ref_seq' => $ref,
				'alt_seq' => $alt,
				'region' => $chr.':'.$start.'-'.$end, 
				'ins_flag' => $insertion_flag,
				'del_flag' => $del_flag, 
			 };

return $g_pu;

}

=head2 formatVarinat
get hash containing location specific information
Inputs
=over 2
=item store_results -store results for printing
=item g_pu -hash containing pileup/exonerate based allele fractions
=item sample -sample name
=back
=cut


sub storeResults {
	my ($self,$store_results,$g_pu,$sample)=@_;
	my $results = {'tMTR'=> '.', 
							   'tWTR'=> '.',
							 	 'tAMB'=> '.',
							 	 'tVAF'=> '.',
							 	 'nMTR'=> '.',
							 	 'nWTR'=> '.',
							 	 'nAMB'=> '.',
							 	 'nVAF'=> '.',								  
		};	
	if (!exists $g_pu->{'alt_p'}) {
		$store_results->{$sample}{$self->getLocation}=$results;
		return $store_results;
	}
	
  my $MTR = $g_pu->{'alt_p'} + $g_pu->{'alt_n'};
	my $WTR = $g_pu->{'ref_p'} + $g_pu->{'ref_n'};
	my $VAF;
	eval {$VAF = $MTR/($MTR+$WTR);};
	$VAF=defined $VAF?sprintf("%.2f",$VAF):'0.0';
 	if ($self->getVarLine=~/BEDFILE/) {
	    my $bed_line=$g_pu->{'chr'}."\t".
	    						 $g_pu->{'start'}."\t".
	    						 $g_pu->{'ref_seq'}."\t".
	    						 $g_pu->{'alt_seq'}."\t".
									 $g_pu->{'normal_MTR'}."\t".
									 $g_pu->{'normal_WTR'}."\t".
									 $g_pu->{'normal_AMB'}."\t".
									 $g_pu->{'normal_VAF'}."\t".
									 $MTR."\t".
									 $WTR."\t".
									 $g_pu->{'amb'}."\t".
									 $g_pu->{'VAF'}."\n";
									 
			$store_results->{"$sample\_bed"}{$self->getLocation}=$bed_line;		
			return $store_results;
		}
	$results->{'tMTR'}=$MTR;
	$results->{'tWTR'}=$WTR;
	$results->{'tAMB'}=$g_pu->{'amb'};
	$results->{'tVAF'}=$VAF;
	
	$results->{'nMTR'}=$g_pu->{'normal_MTR'};
	$results->{'nWTR'}=$g_pu->{'normal_WTR'};
	$results->{'nAMB'}=$g_pu->{'normal_AMB'};
	$results->{'nVAF'}=$g_pu->{'normal_VAF'};
  $store_results->{$sample}{$self->getLocation}=$results;
  
  return $store_results; 
 
}

=head2 getVcfFields
get sample specific original values for INFO and FILTER fields
Inputs
=over 2
=item data_for_all_samples -original VCF fields for a given sample
=back
=cut

sub getVcfFields {
	my($self,$data_for_all_samples)=@_;
	
	return if(!defined $self->getVcfStatus && $self->getVarLine!~/BEDFILE/);
	my $max_depth=0;
	my $flag_val=undef;
	my $original_vcf_info=undef;
	
  foreach my $sample (@{$self->{'_tumourName'}}) {
		if(exists $data_for_all_samples->{$sample}{$self->getLocation} ) {
			my $info_line=$data_for_all_samples->{$sample}{$self->getLocation}->{'INFO'};
			my $filter_val=$data_for_all_samples->{$sample}{$self->getLocation}->{'FILTER'};
			my $max_rd=$data_for_all_samples->{$sample}{$self->getLocation}->{'RD'};
			$max_depth=$max_rd if $max_rd > $max_depth;
			$flag_val->{$sample}=$filter_val;
			$original_vcf_info->{$sample}=$info_line;
		}
		else {
			$original_vcf_info->{$sample}='NA';
			$flag_val->{$sample}='NA';
		}
	}
  
  my ($NFS,$DNFS)=$self->_getFlagStatus($flag_val);
	my ($old_info_val)=$self->_getINFO($original_vcf_info,$DNFS);
	
	return ($old_info_val,$NFS,$flag_val,$max_depth);
}

=head2 _getFlagStatus
get new filter flag value based on original filter defined in VCF
Inputs
=over 2
=item flag_val -Original flag values in filter column
=back
=cut

sub _getFlagStatus {
	my ($self,$flag_val)=@_;
	my $called=0;
	my $passed=0;
	my $not_called=0;
	my $called_n_passed=0;
	my $samples=0;
	my $NFS=0;
	
	foreach my $key (keys %$flag_val) {	
		if ($flag_val->{$key} eq "PASS") 	{$passed++;}
		elsif ($flag_val->{$key} eq "NA")	{$not_called++;}
		else{$called++;}
		$samples++;
		
	}
	$called_n_passed=$called+$passed;
	if ($self->getVarLine=~m/BEDFILE/) {
		return ('BD',"$samples:$called_n_passed:$passed");
	}
	
	# format as per the custom header
	#$vcf_filter{'filter1'}={(key=>'FILTER',ID=>'1',Description=>"New filter status 1=not called in any")}; # use of 0 is not allowed in FILTER column
	#$vcf_filter{'filter2'}={(key=>'FILTER',ID=>'2',Description=>"New filter status 2=called in any")};
	#$vcf_filter{'filter3'}={(key=>'FILTER',ID=>'3',Description=>"New filter status 3=passed  in any")};	
	#$vcf_filter{'filter4'}={(key=>'FILTER',ID=>'BD',Description=>"New filter status BD= location from bed file)};
	#0 - not called; 1 - called ;2 - passed ; 3 - called + passed
	#passed in all
	if(($passed == $samples) && $passed>0 ) { $NFS='PASS'; } #=2
	#called in all
	elsif(($called == $samples) && $passed>0) { $NFS=2; } #= 1
	#not called in all
	elsif(($not_called == $samples) && $not_called>0) { $NFS=1; } #=0
	# passed in all called samples
	elsif(($not_called + $passed == $samples) && $passed > 0 ) { $NFS='PASS'; } #=2
	#called + passed + not called
	#14 20924792 PD9179a PD9179b PD9179c PD9179d [ sample PD9179d doesn't contain the merged location]
	elsif( ( ($passed + $called + $not_called) == $samples ) && ($passed >0 && $called >0)) { $NFS=3; } #=3
	#called but not passed
	elsif( ( ($not_called + $called) == $samples ) && $called > 0) { $NFS=2; } #=1
	# if location is not present in any of the samples -- only valid for bed file., 
	else {$NFS='BD';} #=0
	
	#descriptive flag status added in the INFO field excludes normal sample
	my $DNFS="$samples:$called_n_passed:$passed";
	$NFS,$DNFS;
}
=head2 _get_INFO
parse info field 
Inputs
=over 2
=item original_vcf_info -data from INFO field
=item DNFS -Descriptive flag status [ref header info]
=back
=cut

sub _getINFO {
	my ($self,$original_vcf_info,$DNFS)=@_;
	my $old_info_val;
	foreach my $sample (keys %$original_vcf_info) {
		next if !defined $original_vcf_info->{$sample} || $original_vcf_info->{$sample} eq 'NA';
		my $info=$original_vcf_info->{$sample};
		foreach my $tag (keys %$info) {
			$old_info_val->{$tag}=$info->{$tag};
		}
	}
	$old_info_val->{'NS'}=((split ':', $DNFS)[0]) + scalar keys %{$self->{'_novcf'}};
	$old_info_val->{'NC'}=(split ':', $DNFS)[1];
	$old_info_val->{'NP'}=(split ':', $DNFS)[2];
	$old_info_val->{'NA'}=(split ':', $DNFS)[0];

	return $old_info_val;
}	

=head2 createExonerateInput
Create input files for exonerate 
Inputs
=over 2
=item bam -bam object
=item bam_header -bam header data
=item depth -max depth at this location
=item g_pu -hash containing sample specific info
=back
=cut

sub createExonerateInput {
	my($self,$bam,$bam_header,$depth,$g_pu)=@_;
	$g_pu=$self->_getRange($bam_header,$g_pu,$depth);
	my($ref_seq)=$self->_get_dna_segment($bam,$g_pu->{'chr'},$g_pu->{'pos_5p'},$g_pu->{'pos_3p'});
	my($alt_seq)=$self->_get_alt_seq($bam,$g_pu);
	$g_pu=$self->_get_ref_5p_pos($ref_seq,$alt_seq,$g_pu);
	open (my $ref_n_alt_FH,'>'.$self->{'_tmp'}.'/temp.ref')|| $log->logcroak("unable to open file $!");;
	print $ref_n_alt_FH ">alt\n$alt_seq\n>ref\n$ref_seq\n";
	close($ref_n_alt_FH);
	return($g_pu);
}

=head2 _getRange
get left and right span from indel position
Inputs
=over 2
=item bam_header -sample specific information on read length, chr length and lib size 
=item g_pu -hash containing sample specific info
=item max_depth -max depth at this location
=back
=cut

sub _getRange {
  my($self,$bam_header,$g_pu,$max_depth)=@_;
  
  return unless($self->getVarType eq 'indel');
  my ($left_pos,$right_pos,$chr_len,$spanned_region);
  my $lib_size=$self->{'_libSize'};
  my ($hdr_flag)=$self->_check_hdr_overlap($g_pu->{'chr'},$g_pu->{'start'},$g_pu->{'end'},$self->{'_tabix_hdr'});
  my $spanning_seq_denom=$Sanger::CGP::Vaf::VafConstants::SPANNING_SEQ_DENOMINATOR;
  #if location is in high depth region and has depth >1000 then hdr_flag is true
  if($hdr_flag && $max_depth > 1000){$spanning_seq_denom=4;}
  else {$hdr_flag=0;}
	$chr_len=$bam_header->{$self->{'_normalName'}}{$g_pu->{'chr'}};
  if(defined $lib_size && defined $chr_len) {
  	$spanned_region = round(($lib_size *  $Sanger::CGP::Vaf::VafConstants::INSERT_SIZE_FACTOR )/$spanning_seq_denom);
  	#$spanned_region=round($spanned_region);
  	# 
		if(($spanned_region < $g_pu->{'start'}) && (($chr_len - $g_pu->{'end'}) > $spanned_region)) {
			$left_pos=$g_pu->{'start'} - $spanned_region;
			$right_pos=$g_pu->{'end'} + $spanned_region;
		}else{
		 $left_pos=$g_pu->{'start'} - 50;
		 $right_pos = $g_pu->{'end'} + 50;
		}
	}else{
		$log->logcroak("Library size or chromosome length in not defined");
	}
	
	$g_pu->{'pos_5p'}=$left_pos;
	$g_pu->{'pos_3p'}=$right_pos;
	$g_pu->{'hdr'}=$hdr_flag;
	# to get exact location of variant base and avoid borderline matching   
	# added padding to reference posotion 
	$g_pu->{'ref_pos_5p'}=($g_pu->{'start'} - $g_pu->{'pos_5p'}) + 1 ;
	if($g_pu->{'ins_flag'} && !$g_pu->{'del_flag'}){
		$g_pu->{'ref_pos_3p'}=$g_pu->{'ref_pos_5p'} + ( $g_pu->{'end'} - $g_pu->{'start'} );
	}else{
		$g_pu->{'ref_pos_3p'}=$g_pu->{'ref_pos_5p'} + ( $g_pu->{'end'} - $g_pu->{'start'} ) - 1;
	}
	$g_pu->{'alt_pos_3p'}=$g_pu->{'ref_pos_5p'} + length( $g_pu->{'alt_seq'}) -1;
	return $g_pu;
}

=head2 _check_hdr_overlap
checks overlap with high depth regions 
Inputs
=over 2
=item chr -chromosome number
=item zero_start start coordiante
=item one_end -end coordinate
=tabix - tabix object of bed file containing UCSC high depth regions
=back
=cut
sub _check_hdr_overlap {
	my ($self, $chr, $zero_start, $one_end, $tabix ) = @_;
	$chr=~s/chr//g;
	###
	# Querying is ALWAYS half open regardless of the underlying file type
	###
		my $i=0;
		my $res = $tabix->query("chr$chr", $zero_start, $one_end);
		if(defined $res->get) {
			#if uncomment if want to loop over the hdr regions
			#while(my $record = $tabix->read($res)){
				# the returned data is the ORIGINAL string from the file
				#print "$i : $record\n";
			#}
			$i=1;
			return $i;
		}
	$i;	
}



=head2 _get_dna_segment
get reference dna 
Inputs
=over 2
=item bam_object - Bio::DB sam object
=item chr - chromosome number
=item start - start position
=item end - end position
=back
=cut

sub _get_dna_segment {
	my ($self,$bam_object,$chr,$start,$end)=@_;
	my ($segment)=$bam_object->segment($chr,$start,$end);
	return $segment->dna;
}


=head2 _get_alt_seq
get alternative reference seq
Inputs
=over 2
=item bam_objects - Bio::DB sam object
=item g_pu - hash containing sample specific info
=back
=cut
sub _get_alt_seq {
	my ($self,$bam_objects,$g_pu)=@_;
	#<---1.5*insert_size---[alt_left]|indel|[alt_right]------1.5*insert_size--->	
	my $tmp_start=$g_pu->{'start'};
	my $tmp_end=$g_pu->{'end'};
	#insertion			
	
	if($g_pu->{'ins_flag'} == 1  && $g_pu->{'del_flag'} == 0) {
		$tmp_start= $g_pu->{'start'} - 1;
		$tmp_end= $g_pu->{'end'} + 1;
	}
	#complex indel
	if($g_pu->{'del_flag'} == 1  && $g_pu->{'ins_flag'} == 1) {
		$tmp_start=$g_pu->{'start'} - 1;
	}
	
	my ($alt_left_seq)=$self->_get_dna_segment($bam_objects,$g_pu->{'chr'},$g_pu->{'pos_5p'},$tmp_start);
	my ($alt_right_seq)=$self->_get_dna_segment($bam_objects,$g_pu->{'chr'},$tmp_end,$g_pu->{'pos_3p'});
	#indel[insertion] add alt between two segments...
	my $reconstructed_alt_seq;
	
	if(defined $g_pu->{'ins_flag'} && $g_pu->{'ins_flag'} == 1) {	
		$reconstructed_alt_seq=$alt_left_seq.$g_pu->{'alt_seq'}.$alt_right_seq;			
	}
	#indel[deletion] join two segments...
	else {
		$reconstructed_alt_seq=$alt_left_seq.$alt_right_seq;
	}
	
	return $reconstructed_alt_seq;

}


=head2 _get_ref_5p_pos
get updated 5p positions
Inputs
=over 2
=item ref_seq -reference sequence
=item reconstructed_alt_seq —alternate sequence
=item g_pu -stores relative positions of variant region 
=back
=cut

sub _get_ref_5p_pos {
	my ($self,$ref_seq,$reconstructed_alt_seq,$g_pu) = @_;		
			my $new_pos;
			my $exclusive_OR=$ref_seq^$reconstructed_alt_seq;		
			if($exclusive_OR =~ /[^\0]/g) {
				$new_pos=$-[0]; #gives offset of the beginning of last successful match
				$g_pu->{'new_pos'}=$new_pos;
			}	
		if( ($g_pu->{'ins_flag'}) && ($new_pos != $g_pu->{'ref_pos_5p'}) ){
				my $insert_length = ($g_pu->{'alt_pos_3p'} - $g_pu->{'ref_pos_5p'});
				
				# added for testing....
				#$g_pu->{'old_5p'}=$g_pu->{'ref_pos_5p'};
				#$g_pu->{'old_3p'}=$g_pu->{'ref_pos_3p'};
				#-----
				# get run over after insert string due to match with reference bases
				$g_pu->{'insert_mod'}=($new_pos - $g_pu->{'ref_pos_5p'}) % $insert_length;
				$g_pu->{'alt_pos_3p'}=$new_pos + ($insert_length) - $g_pu->{'insert_mod'};
				$g_pu->{'ref_pos_5p'}=$new_pos;
				$g_pu->{'ref_pos_3p'}=$new_pos;
				
				# added for testing....
				#$g_pu->{'new_5p'}=$g_pu->{'ref_pos_5p'};
				#$g_pu->{'new_3p'}=$g_pu->{'ref_pos_3p'};
				#-----	

		}
	
		return $g_pu,;
}

=head2 populateHash
populate has for chr start and end
Inputs
=over 2
=item g_pu - has containing sample specific info
=item sample - sample name
=item bam_header_data - sample specific information on read length and lib size
=back
=cut

sub populateHash {
  my ($self,$g_pu,$sample,$bam_header_data) = @_;
  
  $g_pu->{'ref_p'} = 0;
	$g_pu->{'ref_n'} = 0;
	$g_pu->{'alt_p'} = 0;
	$g_pu->{'alt_n'} = 0;
	
	$g_pu->{'FAZ'} = 0;
	$g_pu->{'FCZ'} = 0;
	$g_pu->{'FGZ'} = 0;
	$g_pu->{'FTZ'} = 0;
	$g_pu->{'RAZ'} = 0;
	$g_pu->{'RCZ'} = 0;
	$g_pu->{'RGZ'} = 0;
	$g_pu->{'RTZ'} = 0;
	 
	$g_pu->{'amb'} = 0;  
	$g_pu->{'sample'} = $sample; 
	
	return $g_pu if($self->{'_varType'} eq 'snp');
	#if(exists $bam_header_data->{$sample}{'read_length'}){
		$g_pu->{'read_length'}=$bam_header_data->{$sample}{'read_length'};
	#}
	#else {
	#	$g_pu->{'read_length'}=$Sanger::CGP::Vaf::VafConstants::READ_LENGTH;
	#}
	#if(exists $bam_header_data->{$sample}{'lib_size'}){
		$g_pu->{'lib_size'}=$bam_header_data->{$sample}{'lib_size'};
		
		#print "LIB:::: $sample".$bam_header_data->{$sample}{'lib_size'}."-------------\n";
		
	#}
	#else {
	#	$g_pu->{'lib_size'}=$Sanger::CGP::Vaf::VafConstants::READ_LENGTH*2;
	#} 
	# exonerate score is 5 per base , we allow max 4 mismatches * 9 = 36 score units, 4 bases * 5 for readlength = 20 score units to be safe side added another 14 score units
	$g_pu->{'exonerate_score_cutoff'} = (($g_pu->{'read_length'}) * $Sanger::CGP::Vaf::VafConstants::EXONERATE_SCORE_MULTIPLIER) - $Sanger::CGP::Vaf::VafConstants::EXONERATE_SCORE_FACTOR;	                 
  $g_pu;
}

=head2 _fetch_features
get reads in an given location using Bio:Db:Sam fetch method
Inputs
=over 2
=item sam_object - Bio::DB sam object
=item g_pu - hash containing sample specific info
=item Reads_FH - file handler to store reads for a given location
=back
=cut



sub getIndelResults {
	my($self,$bam,$g_pu)=@_;
	open (my $Reads_FH, '>',$self->{'_tmp'}.'/temp.reads') || $log->logcroak("unable to open file $!");
	$g_pu=$self->_fetch_features($bam,$g_pu,$Reads_FH);
	$g_pu=$self->_do_exonerate($self->{'_tmp'}.'/temp.ref',$self->{'_tmp'}.'/temp.reads',$g_pu);
	return $g_pu;
}

=head2 _fetch_features
get reads in an given location using Bio:Db:Sam fetch method
Inputs
=over 2
=item sam_object - Bio::DB sam object
=item g_pu - hash containing sample specific info
=item Reads_FH - file handler to store reads for a given location
=back
=cut


sub _fetch_features {
	my ($self,$sam_object,$g_pu,$Reads_FH)=@_;
	if(($g_pu->{'end'} - $g_pu->{'start'}) < $g_pu->{'lib_size'}){
		$self->_fetch_reads($sam_object, "$g_pu->{'region'}",$Reads_FH);
		$g_pu->{'long_indel'}=0;
	}
	else {
		$self->_fetch_reads($sam_object, "$g_pu->{'chr'}:$g_pu->{'start'}-$g_pu->{'start'}",$Reads_FH);
		$self->_fetch_reads($sam_object, "$g_pu->{'chr'}:$g_pu->{'end'}-$g_pu->{'end'}",$Reads_FH);
		#indel longer than library size set flag on 
		$g_pu->{'long_indel'}=1;
		}
	#only get unmapped reads if not in HDR region and while analysing only PASSED varinat
	if($g_pu->{'hdr'} == 0 && $self->{'_passedOnly'} == 1){
		$self->_fetch_unmapped_reads($sam_object,"$g_pu->{'chr'}:$g_pu->{'pos_5p'}-$g_pu->{'pos_3p'}",$Reads_FH);
	}
close($Reads_FH);
return $g_pu;
}




=head2 _fetch_reads
fetch reads

Inputs
=over 2
=item sam_object - Bio::DB sam object
=item region - chr:start-stop format region info to get reads
=item Reads_FH - temp file handler to store reads
=back
=cut

sub _fetch_reads {
my ($self,$sam_object,$region,$Reads_FH)=@_;
my ($mate_info,%mapped_length);
my $read_counter=0;
		$sam_object->fetch($region, sub {
		my $a = shift;
		my $paired=0;
		my $flags = $a->flag;
		# & bitwise comparison
		## Ignore reads if they match the following flags:
		#Brass/ReadSelection.pm
		
		return if $flags & $Sanger::CGP::Vaf::VafConstants::NOT_PRIMARY_ALIGN;
		return if $flags & $Sanger::CGP::Vaf::VafConstants::VENDER_FAIL;
		return if $flags & $Sanger::CGP::Vaf::VafConstants::UNMAPPED;
	  #return if $flags & $Sanger::CGP::Vaf::VafConstants::DUP_READ;
		return if $flags & $Sanger::CGP::Vaf::VafConstants::SUPP_ALIGNMENT;
		
		#if $flags & $READ_PAIRED;
		#my $cigar  = $a->cigar_str;;
		my $mseqid = $a->mate_seq_id;
		my $seqid = $a->seq_id;
		#target gives read seq as it comes from sequencing machine i.e softclipped bases included
		my $qseq = $a->target->dna();
		return if $qseq =~m/[nN]/;
		my $name=$a->display_name;
		#my $strand = $a->strand;
		my $mstart = $a->mate_start;
		my $start = $a->start;
		$read_counter++;
		print  $Reads_FH ">$name\_$read_counter\n$qseq\n";
	# fetch mate only if on another chromosome
		if(defined $mseqid and defined $seqid and ($seqid ne $mseqid)) {
		#if(defined $mseqid and defined $seqid ) {
			$mate_info->{$name}="$mseqid:$mstart-$mstart";
		}
				
	});
	#added separately as it was pulling only one read 
	foreach my $key (keys %$mate_info)
	{
		$self->_fetch_mate_seq($sam_object,$mate_info->{$key},$key,$Reads_FH);
	}
}
=head2 _fetch_mate_seq
get mate sequence
Inputs
=over 2
=item sam_object - Bio::DB sam object
=item region - postion to get reads
=item readname - mate readname
=item Reads_FH - file handler to store read sequence
=back
=cut

sub _fetch_mate_seq {
	my ($self,$sam_object,$region,$readname,$Reads_FH)=@_;
	my ($read,$mate_seq);
	my $callback= sub {
		my $a = shift; 
		my $flags = $a->flag;
		return if $flags & $Sanger::CGP::Vaf::VafConstants::NOT_PRIMARY_ALIGN;
		return if $flags & $Sanger::CGP::Vaf::VafConstants::VENDER_FAIL;
		return if $flags & $Sanger::CGP::Vaf::VafConstants::UNMAPPED;
	  #return if $flags & $Sanger::CGP::Vaf::VafConstants::DUP_READ;
		return if $flags & $Sanger::CGP::Vaf::VafConstants::SUPP_ALIGNMENT;
		
		if ($readname eq $a->display_name) {
			my $tmp_seq=$a->target->dna();
			return if $tmp_seq=~m/[nN]/;
			$read=$a->display_name;
			$mate_seq=$tmp_seq;
			return;
		}
	};
	
	$sam_object->fetch($region,$callback);
	if($read){
		print  $Reads_FH ">$read\_0\n$mate_seq\n";
	}
}

=head2 _fetch_unmapped_reads
fetch reads whose mate is unmapped
Inputs
=over 2
=item sam_object - Bio::DB sam object
=item region - chr:start-stop format region info to get reads
=item Reads_FH - temp file handler to store reads
=back
=cut

sub _fetch_unmapped_reads {
my ($self,$sam_object,$region,$Reads_FH)=@_;
my ($mate_info,%mapped_length);
my $read_counter=0;
		$sam_object->fetch($region, sub {
		my $a = shift;
		my $paired=0;
		my $flags = $a->flag;
		# & bitwise comparison
		## Ignore reads if they match the following flags:
		#Brass/ReadSelection.pm
		return if $flags & $Sanger::CGP::Vaf::VafConstants::NOT_PRIMARY_ALIGN;
		return if $flags & $Sanger::CGP::Vaf::VafConstants::VENDER_FAIL;
	  #return if $flags & $Sanger::CGP::Vaf::VafConstants::DUP_READ;
		return if $flags & $Sanger::CGP::Vaf::VafConstants::SUPP_ALIGNMENT;
		# only consider reads from wider range where mate is unmapped 
		if ($flags & $Sanger::CGP::Vaf::VafConstants::UNMAPPED) {
			my $qseq = $a->target->dna();
			return if $qseq=~m/[nN]/;
			my $mseqid = $a->mate_seq_id;
			my $seqid = $a->seq_id;
			#target gives read seq as it comes from sequencing machine
			
			my $name=$a->display_name;
			#my $strand = $a->strand;
			my $mstart = $a->mate_start;
			my $start = $a->start;
			$read_counter++;
			print  $Reads_FH ">$name\_$read_counter\n$qseq\n";
			# fetch mate only if on another chromosome
			if(defined $mseqid and defined $seqid and ($seqid ne $mseqid)) {
					$mate_info->{$name}="$mseqid:$mstart-$mstart";
			}
	}
				
	});
	#added separately as it was pulling only one read 
	foreach my $key (keys %$mate_info)
	{
		$self->_fetch_mate_seq($sam_object,$mate_info->{$key},$key, $Reads_FH);
	}
}





=head2 _do_exonerate
parse exonerate output 
Inputs
=over 2
=item ref_seq_file —reference sequence and alt sequences in fasta format
=item temp_read_file  —temp read file in fasta format
=item g_pu -stores relative positions of variant region  
=back
=cut

sub _do_exonerate {
	my($self,$ref_seq_file,$temp_read_file,$g_pu)=@_;
	my $ref_count_p=undef;
	my $ref_count_n=undef;
	my $alt_count_p=undef;
	my $alt_count_n=undef;
	my $read_track_alt=undef;
	my $read_track_ref=undef;
	my $amb_reads=undef;
		
	# -E | --exhaustive <boolean>
  #Specify whether or not exhaustive alignment should be used.  By default, this is FALSE, and alignment heuristics will be used.  If it is set to TRUE, an exhaus‐
  #tive alignment will be calculated.  This requires quadratic time, and will be much, much slower, but will provide the optimal result for the given model. 
  #-S | --subopt <boolean>
  # using exhaustive OFF as it is fast and gives identical answer 
  
  my $cmd="exonerate -E 0 -S 0".
	" --score $g_pu->{'exonerate_score_cutoff'} --percent 95 --fsmmemory 12000 --verbose 0 --showalignment no  --wordjump 3".
	" --querytype dna --targettype dna --query $temp_read_file  --target $ref_seq_file".
	" --showvulgar 0 --bestn 1 --ryo '%qi %ti %qal %tS %tab %tae %qS\n' ";
	#for testing only
	#if($test_mode)
	#{
	#my $cmd2="exonerate -E 0 -S 0".
	#	" --score $g_pu->{'exonerate_score_cutoff'} --percent 95 --fsmmemory 12000 --verbose 0 --showalignment yes --wordjump 3".
	#	" --querytype dna --targettype dna --query $temp_read_file   --target $ref_seq_file".
	#	" --showvulgar 0 --bestn 1 --ryo '%qi %ti %qal %tS %tab %tae %qS\n' ";
	#	my ($exonerate_output1, $stderr1, $exit1) = capture {system("$cmd2")};
	#open (my $tfh1, '>',"exonerate_results_Alignment.out");
	#print $tfh1 $exonerate_output1;
	#my ($exonerate_output2, $stderr2, $exit2) = capture {system("$cmd")};
	
 # }
	
	my ($exonerate_output, $stderr, $exit) = capture {system("$cmd")};
	if ($exit) { $log->logcroak("exonerate log: EXIT:$exit EROOR:$stderr CMD:$cmd"); }
	#----- parse exonerate output ------
	foreach my $line((split("\n", $exonerate_output))) {
		my ($read,$target,$match_len,$t_strand,$t_start,$t_end,$q_strand)=(split ' ', $line);
		if ($match_len < ($g_pu->{'read_length'} - $Sanger::CGP::Vaf::VafConstants::READ_LENGTH_CUTOFF)) {
		 next;
		}
		my $strand=$t_strand;
		#<--5p--|*******|--3p-->
		my $temp_start=$t_start;
		my $org_read=$read;
		$read=~s/_\d+$//g;
		if($strand eq '-') { $t_start=$t_end ; $t_end=$temp_start;}
		if( $target eq 'ref') {	
			# ref_pos stores the varinat interval relative to subset created using gnomic seq	
			if( ($t_start < $g_pu->{'ref_pos_5p'} &&  $t_end >$g_pu->{'ref_pos_5p'}) || ($t_start < $g_pu->{'ref_pos_3p'} &&  $t_end >$g_pu->{'ref_pos_3p'}) ) 
			{
				$read_track_ref->{$org_read}++;
				if($strand eq '+') {
				#store diff to check the distance of variant pos from either end of the read
					$ref_count_p->{$read} = abs( ($g_pu->{'ref_pos_5p'} - $t_start) - ($t_end - $g_pu->{'ref_pos_3p'}) )
				} 
				else {
					$ref_count_n->{$read} = abs( ($g_pu->{'ref_pos_5p'} - $t_start) - ($t_end - $g_pu->{'ref_pos_3p'}) );
				}
			}			
		}
		# checks overlap...
		elsif( ($t_start < $g_pu->{'ref_pos_5p'} &&  $t_end >$g_pu->{'ref_pos_5p'} ) || ($t_start < $g_pu->{'alt_pos_3p'} &&  $t_end >$g_pu->{'alt_pos_3p'}) )  
		{
			$read_track_alt->{$org_read}++;
			if($strand eq '+') {
				$alt_count_p->{$read} = abs( ($g_pu->{'ref_pos_5p'} - $t_start) - ($t_end - $g_pu->{'alt_pos_3p'}) );
			} 
			else {
				$alt_count_n->{$read} = abs( ($g_pu->{'ref_pos_5p'} - $t_start) - ($t_end - $g_pu->{'alt_pos_3p'}) );
			}
		}
	}	

$g_pu=$self->_cleanup_read_ambiguities($g_pu,$read_track_alt,$read_track_ref, $alt_count_p,$alt_count_n,$ref_count_p,$ref_count_n); 

return $g_pu;


}


=head2 _cleaup_read_ambiguities
cleaup of ambiguous reads and read of a same read pair mapping on +ve and/or -ve strand at same location
Inputs
=over 2
=item g_pu -- stores relative positions of variant region  
=item read_track_alt —hash stroring reads mapping on alt base
=item read_track_ref  —hash stroring reads mapping  on ref base
=item  alt_count_p  —hash stroring +ve reads mapping  on alt base
=item  alt_count_n  —hash stroring -ve reads mapping  on alt base
=item  ref_count_p  —hash stroring +ve reads mapping  on ref base
=item  ref_count_n  —hash stroring -ve reads mapping  on ref base
=back
=cut

sub _cleanup_read_ambiguities {
	my ($self,$g_pu,$read_track_alt,$read_track_ref,$alt_count_p,$alt_count_n,$ref_count_p,$ref_count_n)=@_;
	my $amb_reads;
	foreach my $read (sort keys %$read_track_alt) {
			if(exists $read_track_ref->{$read}) {
				
				$read=~s/_\d+$//g;
				delete $ref_count_n->{$read} if $ref_count_n->{$read};
				delete $ref_count_p->{$read} if $ref_count_p->{$read};
				delete $alt_count_n->{$read} if $alt_count_n->{$read};
				delete $alt_count_p->{$read} if $alt_count_p->{$read};
				$amb_reads->{$read}++;
			}
		}	
	
	# check if read pairs maps at same location , consider only one read from pair which is aligned properly to variant site 
	foreach my $read (sort keys %$ref_count_p) {
		# if variant position on +ve strand is towards middle of the read then remove read from -ve strand 
		if ($ref_count_n->{$read}) {
			if($ref_count_p->{$read} < $ref_count_n->{$read}) {
				delete $ref_count_n->{$read};
			}
			else {
				delete $ref_count_p->{$read};
			}
		}
	}
	foreach my $read (sort keys %$alt_count_p) {
		# if variant position on +ve strand is towards middle of the read then remove read from -ve strand 
		if ($alt_count_n->{$read}) {
			if($alt_count_p->{$read} < $alt_count_n->{$read}) {
				delete $alt_count_n->{$read};
			}
			else {
				delete $alt_count_p->{$read};
			}
		}
	}

		if($ref_count_p) { $g_pu -> {'ref_p'}=keys %$ref_count_p; }
		if($ref_count_n) { $g_pu -> {'ref_n'}=keys %$ref_count_n; }
		if($alt_count_p) { $g_pu -> {'alt_p'}=keys %$alt_count_p; }
		if($alt_count_n) { $g_pu -> {'alt_n'}=keys %$alt_count_n; }
		if($amb_reads)	 { $g_pu -> {'amb'}=keys %$amb_reads; }
			
return $g_pu;

}


=head2 addNormalCount
add count for normal sample
Inputs
=over 2
=item g_pu - has containing sample specific info
=back
=cut

sub addNormalCount {
	my($self,$g_pu)=@_;
	my $VAF;
						$g_pu->{'normal_MTR'}=$g_pu->{'alt_p'} + $g_pu->{'alt_n'};
						$g_pu->{'normal_WTR'}=$g_pu->{'ref_p'} + $g_pu->{'ref_n'};
						eval{$VAF=$g_pu->{'normal_MTR'}/($g_pu->{'normal_WTR'}+$g_pu->{'normal_MTR'}); };
						$g_pu->{'normal_VAF'}=defined $VAF?sprintf("%.2f",$VAF):'0.00';
						$g_pu->{'normal_AMB'}=$g_pu->{'amb'};
						
	return $g_pu;
}

=head2 _get_pileup
get pileup output for given location
Inputs
=over 2
=item bam_object - Bio::DB sam object
=item g_pu - hash containing sample specific info
=back
=cut


sub getPileup {
	my ($self,$bam_object,$g_pu)=@_;
		$bam_object->fast_pileup($g_pu->{'region'}, sub {
									my ($seqid, $pos, $pu) = @_;
									return if($pos != $g_pu->{'start'});
									my $refbase = $bam_object->segment($seqid,$pos,$pos)->dna;
									foreach my $p (@{$pu}) {
										next if($p->is_del || $p->is_refskip);
										my $a = $p->alignment;
										my $flags = $a->flag;
										# \& bitwise comparison
										##Ignore reads if they match the following flags:
										#Brass-ReadSelection.pm
										next if $flags & $Sanger::CGP::Vaf::VafConstants::NOT_PRIMARY_ALIGN;
										next if $flags & $Sanger::CGP::Vaf::VafConstants::VENDER_FAIL;
										next if $flags & $Sanger::CGP::Vaf::VafConstants::DUP_READ;
										next if $flags & $Sanger::CGP::Vaf::VafConstants::SUPP_ALIGNMENT;
										#next if($g_pu_mapq && $a->qual < $g_pu_mapq);
										#if($g_pu_baseq) {
										#	my $fa = Bio::DB::Bam::AlignWrapper->new($a, $bam_object);
										#	my $qual = ($fa->qscore)[$p->qpos];
											#next if($qual <= $g_pu_baseq);
										#}
										# get the base at this pos
										#my $refbase = $bam_object->segment($seqid,$pos,$pos)->dna;
										my $qbase  = substr($a->qseq, $p->qpos, 1);
										my $strand = $a->strand;
										next if $qbase =~/[nN]/; #in case of insertion ....
										#$g_pu->{'depth'}++; # commented as for paired end it is calculated twice
										my $key;
										if(($refbase eq $qbase) && $strand > 0) {
											$g_pu->{'ref_p'}++;
											$key='F'.$qbase.'Z';
										}
										elsif(($refbase eq $qbase) && $strand < 0) {
											$g_pu->{'ref_n'}++;
											$key='R'.$qbase.'Z';
										}
										elsif(($g_pu->{'alt_seq'} eq $qbase) && $strand > 0) {
											$g_pu->{'alt_p'}++;
											$key='F'.$qbase.'Z';
										}
										elsif(($g_pu->{'alt_seq'} eq $qbase) && $strand < 0) {
											$g_pu->{'alt_n'}++;
											$key='R'.$qbase.'Z';
										}
										elsif ($strand > 0 ) {
											$key='F'.$qbase.'Z';
										}
										elsif ($strand < 0 ) {
											$key='R'.$qbase.'Z';
										}
										
										
										$g_pu->{$key}++;

									}
		});
	
	return $g_pu;	
}

=head2 formatResults
format pileup/ exonerate results as per VCF specifications
=over 2
=item original_flag -orignal flag values
=item g_pu -hash containing results and sample specific info for give location
=back
=cut

sub formatResults {
	my ($self,$original_flag,$g_pu)=@_;
	my $VCF_OFS;	
	my $pileup_results;
	if(defined $original_flag->{$g_pu->{'sample'}}) {
		$VCF_OFS=$original_flag->{$g_pu->{'sample'}};
	}
	else {
		$VCF_OFS='NA';
	}
	my $MTR = $g_pu->{'alt_p'} + $g_pu->{'alt_n'};
	my $WTR = $g_pu->{'ref_p'} + $g_pu->{'ref_n'};
	my $DEP = $MTR + $WTR + $g_pu->{'amb'};
	
	## determine read direction
	my $MDR =0;
	# only +ve reads 
	if($g_pu->{'alt_p'} > 0 && $g_pu->{'alt_n'} == 0 ) 
	{ $MDR=1; }
	# only -ve reads
	elsif($g_pu->{'alt_p'} == 0 && $g_pu->{'alt_n'} > 0 ) 
	{ $MDR=2; }
	# +ve & -ve
	elsif($g_pu->{'alt_p'} > 0 && $g_pu->{'alt_n'} > 0 )
	 { $MDR=3; }
 
	my $WDR=0;
	# only +ve
	if($g_pu->{'ref_p'} > 0 && $g_pu->{'ref_n'} == 0 )
	{ $WDR=1; }
	# only -ve
	elsif($g_pu->{'ref_p'} == 0 && $g_pu->{'ref_n'} > 0 ) 
	{ $WDR=2; }
	# +ve & -ve
	elsif($g_pu->{'ref_p'} > 0 && $g_pu->{'ref_n'} > 0 ) 
	{ $WDR=3; }
	
	my $VAF;
	eval {$VAF = $MTR/($MTR+$WTR);};
	$VAF=defined $VAF?sprintf("%.2f",$VAF):'0.0';
	
	if($self->getVarType ne 'indel') {
	$pileup_results={ 
										'FAZ' =>$g_pu->{'FAZ'},
										'FCZ' =>$g_pu->{'FCZ'},
										'FGZ' =>$g_pu->{'FGZ'},
										'FTZ' =>$g_pu->{'FTZ'},
										'RAZ' =>$g_pu->{'RAZ'},
										'RCZ' =>$g_pu->{'RCZ'},
										'RGZ' =>$g_pu->{'RGZ'},
										'RTZ' =>$g_pu->{'RTZ'},
										'MTR'	=>$MTR,
										'WTR'	=>$WTR,
										'DEP'	=>$DEP,
										'MDR'	=>$MDR,
										'WDR'	=>$WDR,
										'OFS'	=>$VCF_OFS,
										'VAF' =>$VAF,
										};
	}
	
	else {
	$pileup_results={ 'MTR'	=>$MTR,
										'WTR'	=>$WTR,
										'DEP'	=>$DEP,
										'MDR'	=>$MDR,
										'WDR'	=>$WDR,
										'OFS'	=>$VCF_OFS,
										'AMB'	=>$g_pu->{'amb'},
										'VAF'	=>$VAF
										};
	}
		
$pileup_results;	
}





