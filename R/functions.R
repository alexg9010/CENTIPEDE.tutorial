# functions.R
# Kamil Slowikowski
# July  3, 2015
#
# Helper Functions for CENTIPEDE.

#' Parse a genomic region into parts.
#'
#' @param region A string like "chr1:123-456".
#' @return A list with elements "chrom", "start", and "end".
#' @export
parse_region <- function(region) {
  xs <- strsplit(region, ":")[[1]]
  chrom <- xs[1]
  xs <- as.numeric(strsplit(xs[2], "-")[[1]])
  return(list("chrom" = chrom, "start" = xs[1], "end" = xs[2]))
}

#' Read a bedGraph file with 4 columns: chrom, start, end, score
#'
#' @param filename The file to read.
#' @param ... Additional parameters passed to read.delim.
#' @return A GRanges object.
#' @export
read_bedGraph <- function(filename, ...) {
  dat <- read.delim(
    filename, header = FALSE, stringsAsFactors = FALSE, ...)
  colnames(dat) <- c("chrom", "start", "end", "score")
  makeGRangesFromDataFrame(
    df = dat,
    keep.extra.columns = TRUE,
    ignore.strand = TRUE,
    starts.in.df.are.0based = TRUE
  )
}

#' Read a text file output by FIMO and select sites that meet a significance
#' threshold.
#'
#' @param fimo_file A FIMO text file with PWM match sites.
#' @param log10p Select FIMO matches with log10 p-value greater than this.
#' @return A dataframe with one row per site.
#' @details
#'    For sites represented multiple times, the one with the maximum
#'    score is selected.
#' @export
read_fimo <- function(fimo_file, log10p = 4,...) {
  # Read the PWM sites.
  sites <- read.delim(fimo_file,...)
  
  # Discard poor matches.
  sites <- sites[-log10(sites$p.value) > log10p, , drop = FALSE]
  
  # For sites represented multiple times, select the one with the max score.
  sites$region <- paste(sites$sequence.name, sites$start, sites$stop)
  # sort sites according to regions and descending score
  sites <- sites[with(sites, order(sequence.name, start, stop,-score)),]
  # find duplicated regions and remove the ones with lower scores
  dups <- duplicated(sites$region)
  if( sum(dups) > 0 ) sites <- sites[-which(dups),]
  
  sites <- sites[ , !colnames(sites) %in% c("region")]
  
  # Ensure we have some matches.
  if (nrow(sites) == 0) {
    stop(sprintf("No significant sites for '%s'", fimo_file))
  }
  
  return(sites)
}

#' Count readstarts at each nucleotide position in each BED region.
#'
#' @param bam_file A BAM file with mapped DNase-Seq data.
#' @param fimo_file A FIMO text file with PWM match sites.
#' @param log10p Select FIMO matches with log10 p-value greater than this.
#' @return A list with two items "mat" and "regions".
#' @details
#'    The returend matrix "mat" has one row for each region in the BED
#'    file, and one column for each genomic position.
#'    The returned dataframe "regions" described each region with a p-value
#'    and q-value from FIMO.
#' @export
centipede_data <- function(bam_file, fimo_file, log10p = 4, flank_size = 100, ...) {
  # Read the FIMO output file.
  sites <- read_fimo(fimo_file,log10p,...)
  
  # Upstream flank, the center of PWM match, and downstream flank.
  #motif_center <- floor(nchar(as.character(sites$matched.sequence))/2)
  #sites$start <- sites$start - ( flank_size + motif_center )
  #sites$stop <- sites$stop + ( flank_size  - motif_center ) 
  sites$start <- sites$start - flank_size 
  sites$stop <- sites$stop + flank_size
  # Order the PWM binding sites by chr, start, end.
  #sites <- sites[with(sites, order(sequence.name, start, stop)), ]

  # Index the BAM file if necessary.
  bam_index_file <- sprintf("%s.bai", bam_file)
  if (!file.exists(bam_index_file)) {
    message("Indexing the BAM file... this may take several minutes.")
    indexBam(bam_file, overwrite = FALSE)
  }

  # Extract reads that overlap the PWM sites.
  bam <- Rsamtools::scanBam(
    file = bam_file,
    param = Rsamtools::ScanBamParam(
      which = GRanges(
        seqnames = sites$sequence.name,
        ranges = IRanges(
          start = sites$start,
          end = sites$stop
        )
      ),
      what = c("strand", "pos", "qwidth")
    )
  )

  if (length(bam) == 0) {
    stop(sprintf("No reads fall in sites from '%s'\n", fimo_file))
  }

  # Convert the list of "chr:start-end" regions to a dataframe.
  regions <- lapply(names(bam), parse_region)
  regions <- data.frame(
    sequence.name = unlist(sapply(regions, function(x) x["chrom"])),
    start = as.numeric(unlist(sapply(regions, function(x) x["start"]))),
    stop = as.numeric(unlist(sapply(regions, function(x) x["end"])))
  )
  regions$index <- 1:nrow(regions)

  # Grab score, p.value, and q.value, but drop regions with no reads.
  regions <- merge(regions, sites)

  # Sort the regions by coordinate.
  regions <- regions[with(regions, order(sequence.name, start, stop)),]
  bam <- bam[regions$index]

  # Drop unused columns.
  regions <- regions[,!colnames(regions) %in% c("index")]

  if (nrow(regions) != length(bam)) {
    stop(sprintf("ERROR: %d regions and %d in bam. '%s'\n",
                 nrow(regions), length(bam), fimo_file))
  }

  mat <- do.call(rbind, lapply(seq(1, length(bam)), function(i) {

    # The reads overlapping this region.
    region <- parse_region(names(bam)[i])
    len <- abs(region$end - region$start) + 1

    # Exclude reads with start positions outside the region.
    item <- bam[[i]]
    
    # take care of negative reads starting at end position
    neg_shift <- item$qwidth * as.numeric(item$strand == "-")
    item$pos <- item$pos + neg_shift
    
    idx <- item$pos >= region$start & item$pos <= region$end
    if (sum(idx) == 0) {
      return(rep(0, 2 * len))
    }
    strand <- item$strand[idx]
    position <- item$pos[idx]
    
    # Create a row that represents the flanking region surrounding a site, 
    # each column is a position relative to the center of the motif match. 
    # The values in this matrix are number of read start- sites that occur at that position. 
    # We simply concatenate the forward and reverse strands together for the purpose of model fitting.
    # The row contains entries for the positive followed by negative strands.
    is.neg <- as.numeric(strand == "-")
    j <- 1 + position - min(position) + (len * is.neg)

    as.numeric(table(factor(j, levels = seq(1, 2 * len))))
  }))
  rownames(mat) <- names(bam)

  list(mat = mat, regions = regions)
}

# TODO: Create better functions for viewing CENTIPEDE results.
#
# imageReadStarts <- function(mat, site.width = 13) {
#   # Try using image() ...
#   image(t(mat), useRaster = TRUE, axes = FALSE)
#   len <- ncol(mat) / 2
#   axis(
#     side = 1,
#     at = c(
#       (len / 2 - site.width) / ncol(mat),
#       (len / 2 + site.width) / ncol(mat)
#     ),
#     labels = c("", "")
#   )
#   axis(
#     side = 1,
#     at = c(
#       (len + (len / 2 - site.width)) / ncol(mat),
#       (len + (len / 2 + site.width)) / ncol(mat)
#     ),
#     labels = c("", "")
#   )
#
#   # Also try using grid.raster() ...
#   img <- 1 - mat / max(mat)
#   w <- convertUnit(unit(ncol(img),"pt"), "in", value=TRUE)
#   h <- convertUnit(unit(nrow(img),"pt"), "in", value=TRUE)
#
#   # dev.new(width=w, height=h)
#
#   grid.raster(
#     image = img,
#     width = unit(1, "npc"),
#     height = unit(1, "npc")
#   )
#
#   v = dataViewport(xData = d$x, yData = d$y)
#   grid.points(d$x,d$y, default.units="native", vp = v,
#               gp=gpar(col="white"), pch=8)
# }
