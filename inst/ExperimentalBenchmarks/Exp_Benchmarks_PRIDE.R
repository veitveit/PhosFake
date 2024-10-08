library(bigmemory)
library(moments)
library(stringr)
source ("06_Benchmarks.R")


############ Call the function to load and prepare data, and then to calculate the benchmarks
### It is now adopted to download files from PRIDE according to the metadata
library(jsonlite)
## General parameters
withGroundTruth <- F
tmpdir <- "tmp"
tmpdir <- normalizePath(tmpdir)

#allPRIDE <- readLines("pxd_accessions.json")
allPRIDE <- read.csv(unz("pride_df.zip","pride_df.csv"), stringsAsFactors = F)

for (pxd in 1:nrow(allPRIDE))  {
  
  tdat <- allPRIDE[pxd,]
  modpep <- protlist <- NULL
  if (!is.null(tdat$dataProcessingProtocol)) {
    # if maxquant
    try({
      if (grepl("maxquant",tolower(tdat$dataProcessingProtocol)) ) {
        print(pxd)
        tfile_list <- read_json(paste0("https://www.ebi.ac.uk/pride/ws/archive/v2/files/byProject?accession=",tdat$accession))
        file_types <- sapply(tfile_list, function(x) x$fileCategory$value)
        file_list <- sapply(tfile_list, function(x) ifelse(grepl("ftp://",x$publicFileLocations[[1]]$value), x$publicFileLocations[[1]]$value, x$publicFileLocations[[2]]$value ))
        # if maxquant files available
        if (any(grepl("/modificationSpecificPeptides.txt",file_list)) &  any(grepl("/proteinGroups.txt",file_list))) {
          modpep <- read.csv(grep("/modificationSpecificPeptides.txt",file_list, value=T), sep="\t")
          protlist <- read.csv(grep("/proteinGroups.txt",file_list, value=T), sep="\t")
          # if maxquant files in zip file
        } else if (any(file_types == "SEARCH" & grepl(".zip",file_list) )) {
          filenames <- file_list[which(file_types == "SEARCH" & grepl(".zip",file_list))]
          for (filename in filenames) {
            tempfile <- tempfile(tmpdir=tmpdir)
            print(filename)
            download.file(filename, tempfile, mode="wb")
            #              filelist <- unzip(tempfile, list=T)$Name
            filelist <- system(paste0("jar tf ", tempfile), intern=T)
            # non-optimal: takes only the first of the files if multiples are available in zip-file     
            if (any(grepl("modificationSpecificPeptides.txt",filelist)) & any(grepl("proteinGroups.txt",filelist))) {
              #	    print(filelist)
              dfile <- grep("modificationSpecificPeptides.txt",filelist, value=T)[1]
              system(paste0("cd ",tmpdir,";jar xvf ",tempfile," \"",dfile,"\""))
              tdfile <- paste0(tmpdir,"/", dfile)
              modpep <- read.csv(tdfile, sep="\t")
              file.remove(tdfile)
              dfile <- grep("proteinGroups.txt",filelist, value=T)[1]
              tdfile <- paste0(tmpdir,"/", dfile)
              system(paste0("cd ",tmpdir,";jar xvf ",tempfile," \"",dfile,"\""))
              protlist <- read.csv(tdfile, sep="\t")
              file.remove(tdfile)
            }
            file.remove(tempfile)
            
            # if both files are non-zero
            if (!is.null(modpep) & !is.null(protlist)) {
              try({
                MQout <- readMaxQuant(modpep, protlist)
                allPeps <- MQout$allPeps
                Prots <- MQout$Prots
                Param <- MQout$Param
                Benchmarks <- NULL
                rownames(allPeps) <- paste0("pep", 1:nrow(allPeps))
                if (withGroundTruth) {
                  Stats <- runPolySTest(Prots, Param, refCond=1, onlyLIMMA=F)
                  # much faster with only LIMMA tests   
                  StatsPep <- runPolySTest(allPeps, Param, refCond=1, onlyLIMMA=T)
                  Benchmarks <- calcBenchmarks(Stats, StatsPep, Param)
                } else {
                  Benchmarks <- calcBasicBenchmarks(Prots, allPeps, Param)
                }
                
                ### Get additional benchmarks only for experimental data
                ## Max. difference retention time
                Benchmarks$globalBMs$diffRetentionTime <- diff(range(MQout$allPeps$Retention.time))
                
                ## Number of accepted PSMs (count scan numbers)
                Benchmarks$globalBMs$acceptedPSMs <- sum(MQout$allPeps$MS.MS.Count)
                
                save(Benchmarks, Prots, allPeps, Param, tdat, file =paste0("benchmarks_",which(filename==filenames),"_",tdat$accession, ".RData") )
              })
            }
          }
        }
      }
    })
  }
}



benchmarks <- list.files("./","benchmarks")
AllExpBenchmarks <- AllProts <- AllPeps <- numQuantCol <- NULL
for (bench in benchmarks) {
  try({
    load(bench)
    print(bench)
    if (withGroundTruth) {
      Stats <- runPolySTest(Prots, Param, refCond=1, onlyLIMMA=F)
      # much faster with only LIMMA tests   
      StatsPep <- runPolySTest(allPeps, Param, refCond=1, onlyLIMMA=T)
      Benchmarks <- calcBenchmarks(Stats, StatsPep, Param)
    } else {
      
      Benchmarks <- calcBasicBenchmarks(Prots, allPeps, Param)
    }
    
    AllProts[[bench]] <- Prots[,"Accession"]
    AllProts[[bench]] <- AllProts[[bench]][!is.na(AllProts[[bench]])]
    AllPeps[[bench]] <- cbind(SeqMod=paste0(allPeps[,"Sequence"], allPeps[,"Modifications"]))
    numQuantCol[[bench]] <- Param$QuantColnames
    
    
    ### Get additional benchmarks only for experimental data
    ## Max. difference retention time
    Benchmarks$globalBMs$diffRetentionTime <- diff(range(allPeps$Retention.time))
    
    ## Number of accepted PSMs (count scan numbers)
    Benchmarks$globalBMs$acceptedPSMs <- sum(allPeps$MS.MS.Count)
    
    
    save(Benchmarks, Prots, allPeps, Param, tdat, file =bench)
    AllExpBenchmarks[[bench]] <- unlist(c(Benchmarks$globalBMs, tdat))
  })
}

save(AllExpBenchmarks, file="AllExpBenchmarks.RData")


# getting all protein names and peptide sequences
AllAccs <- unlist(AllProts)
AllSeqs <- unlist(AllPeps)
AllAccs <- unique(AllAccs)
AllSeqs <- unique(AllSeqs)


# save all protein names and peptide sequence
save(numQuantCol, AllAccs, AllSeqs, file="FullProtPepList.RData")
# probably better alternative: use sparse matrices from Matrix package, + cBind

library(Matrix)
load("FullProtPepList.RData")
benchmarks <- list.files("./","benchmarks")
#benchmarks <- benchmarks[1:10]

# writing full tables
print(paste("Altogether", sum(sapply(numQuantCol, length)), "columns"))
cols <- NULL
for (bench in benchmarks) {
  cols <- c(cols, paste(bench,numQuantCol[[bench]],sep="_"))
}

# fill with 1  value to make the mode double
fullProtTable <- sparseMatrix(dims = c(length(AllAccs),length(cols)), dimnames=list(x=AllAccs, y=cols), x=1.1, i={1}, j={1})
fullProtTable[1,1] <- 0
#fullProtTable <- matrix(NA, nrow=length(AllAccs), ncol=length(benchmarks), dimnames=list(x=AllAccs, y=names(benchmarks)))
for (bench in benchmarks) {
  try({
    load(bench)
    print(bench)
    cols <- paste(bench,numQuantCol[[bench]],sep="_")
    AllProts <- Prots[,c("Accession",Param$QuantColnames)]
    AllProts <- AllProts[!is.na(AllProts[,1]),]
    poss <- match(as.character(AllProts[,1]), AllAccs)
    for (c in cols) {
      print(c) 
      fullProtTable[poss, c] <- AllProts[,(which(cols==c)+1)]
    }
  })
} 
save(fullProtTable, file="FullProtQuant.RData")

# fullPepTable <- sparseMatrix(dims = c(length(AllSeqs),length(cols)), dimnames=list(x=AllSeqs, y=cols), x=1.1, i={1}, j={1})

# separate into junks of ch_size peptides
ch_size <- 100000
fullPepTable <- seq_chunk <- NULL
for (c in 1:ceiling(length(AllSeqs)/ch_size)) {
  seq_chunk[[c]] <- AllSeqs[((c-1)*ch_size+1):min(c*ch_size, length(AllSeqs))]  
  fullPepTable[[c]] <- sparseMatrix(dims = c(length(seq_chunk[[c]]),1), dimnames=list(x=seq_chunk[[c]], y="X"), x=1.1, i={1}, j={1})
  fullPepTable[[c]][1,1] <- 0
}
#fullPepTable <- sparseMatrix(dims = c(length(AllSeqs),1), dimnames=list(x=AllSeqs, y="X"), x=1.1, i={1}, j={1})
#fullPepTable <- matrix(NA, nrow=length(AllSeqs), ncol=length(benchmarks), dimnames=list(x=AllSeqs, y=names(benchmarks)))
for (bench in benchmarks) {
  # try({
  load(bench)
  print(" ")
  print(paste("Pep", bench, dim(allPeps)),collapse=" ")
  cols <- paste(bench,numQuantCol[[bench]],sep="_")
  AllPeps <- data.frame(SeqMod=paste0(allPeps[,"Sequence"], allPeps[,"Modifications"]),allPeps[,Param$QuantColnames])
  colnames(AllPeps) <- c("modseq",Param$QuantColnames)
  # fullPepTable[as.character(AllPeps[,1]), cols] <- AllPeps[,2:(which(cols==c)+1)]
  # poss <- match(as.character(AllPeps[,1]), AllSeqs)
  poss <- AllSeqs %in% as.character(AllPeps[,1])
  ttable <- sparseMatrix(dims = c(length(AllSeqs),ncol(AllPeps)-1), dimnames=list(x=AllSeqs, y=cols), x=1.1, i={1}, j={1})
  ttable[1,1] <- 0
  # for (c in cols) {
  #   print(paste(c))
  #   ttable[poss, c] <- as.numeric(AllPeps[,(which(cols==c)+1)])
  #   #fullPepTable[poss, c] <- as.numeric(AllPeps[,(which(cols==c)+1)])
  # }
  ttable[poss, ] <- as.matrix(AllPeps[,numQuantCol[[bench]], drop=F])
  # colnames(ttable) <- cols
  pb <- txtProgressBar(min = 0, max = length(AllSeqs), style = 3)
  for (ch in 1:length(seq_chunk)) {
    setTxtProgressBar(pb, (ch-1)*ch_size)
        fullPepTable[[ch]] <- cbind(fullPepTable[[ch]],ttable[((ch-1)*ch_size+1):min(ch*ch_size, length(AllSeqs))])
  }
  #fullPepTable[,which(colnames(fullPepTable) %in% cols)] <- ttable
  # for (c in cols) {
  #    print(c) 
  #    fullPepTable[, c] <- ttable[,(which(cols==c)+1)]
  #  }
  # # 
  # })
} 
save(fullPepTable, file="FullPepQuant.RData")



