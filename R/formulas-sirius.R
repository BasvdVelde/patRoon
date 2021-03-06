#' @include main.R
#' @include mspeaklists.R
#' @include formulas.R
#' @include utils-sirius.R
NULL

# callback for executeMultiProcess()
processSIRIUSFormulas <- function(msFName, outPath, cmpName, adduct, hash, isPre44, cacheDB, ...)
{
    noResult <- forms <- data.table(neutral_formula = character(0), formula = character(0),
                                    adduct = character(0), score = numeric(0), MSMSScore = numeric(0),
                                    isoScore = numeric(0), byMSMS = logical(0),
                                    frag_neutral_formula = character(0), frag_formula = character(0),
                                    frag_mz = numeric(0), frag_formula_mz = numeric(0), frag_intensity = numeric(0),
                                    neutral_loss = character(0), explainedPeaks = integer(0), explainedIntensity = numeric(0))
    
    
    resFile <- if (isPre44) "summary_sirius.csv" else "formula_candidates.tsv"
    resultPath <- getSiriusResultPath(outPath, msFName, cmpName, isPre44)
    summary <- file.path(resultPath, resFile)
    if (length(summary) == 0 || length(summary) == 0 || !file.exists(summary))
        forms <- noResult
    else
    {
        forms <- fread(summary)
        fragFiles <- getSiriusFragFiles(resultPath, isPre44)
        
        if (nrow(forms) == 0 || length(fragFiles) == 0)
            forms <- noResult
        else
        {
            if (isPre44)
                setnames(forms, c("formula", "treeScore"), c("neutral_formula", "MSMSScore"))
            else
            {
                setnames(forms, c("molecularFormula", "precursorFormula", "SiriusScore",
                                  "TreeScore", "IsotopeScore", "numExplainedPeaks", "medianMassErrorFragmentPeaks(ppm)",
                                  "medianAbsoluteMassErrorFragmentPeaks(ppm)", "massErrorPrecursor(ppm)"),
                         c("neutral_formula", "neutral_adduct_formula", "score", "MSMSScore", "isoScore",
                           "explainedPeaks", "error_frag_median", "error_frag_median_abs", "error"))
            }
            
            frags <- rbindlist(lapply(fragFiles, function(ff)
            {
                fragInfo <- fread(ff)
                setnames(fragInfo,
                         c("mz", "intensity", "exactmass", if (isPre44) "explanation" else "formula"),
                         c("frag_mz", "frag_intensity", "frag_formula_mz", "frag_neutral_formula"))
                fragInfo[, rel.intensity := NULL]
                if (!isPre44)
                    fragInfo[, ionization := NULL]
                fragInfo[, neutral_adduct_formula := getFormulaFromSiriusFragFile(ff, isPre44)]
                return(fragInfo)
            }))
            
            # merge fragment info
            forms <- merge(forms, frags, by = "neutral_adduct_formula")
            
            forms[, formula := calculateIonFormula(neutral_formula, ..adduct)]
            forms[, frag_formula := calculateIonFormula(frag_neutral_formula, ..adduct)]
            forms[, neutral_loss := as.character(Vectorize(subtractFormula)(formula, frag_formula))]
            forms[, byMSMS := TRUE]
            forms[, rank := NULL]
            
            # Precursor is always present in MS/MS spectrum: it's added by
            # SIRIUS if necessarily (with zero intensity). Remove it and use its
            # frag_formula_mz to get the formula_mz
            forms[, formula_mz := .SD[frag_formula == formula, frag_formula_mz], by = "formula"]
            forms <- forms[frag_intensity != 0 | formula != frag_formula]
            
            # set nice column order
            setcolorder(forms, c("neutral_formula", "formula", "neutral_adduct_formula", "formula_mz", "error", "error_frag_median",
                                 "error_frag_median_abs", "adduct", "score", "MSMSScore", "isoScore", "byMSMS",
                                 "frag_neutral_formula", "frag_formula", "frag_mz", "frag_formula_mz", "frag_intensity", "neutral_loss",
                                 "explainedPeaks", "explainedIntensity"))
            
            forms <- rankFormulaTable(forms)
        }
    }
    saveCacheData("formulasSIRIUS", forms, hash, cacheDB)
    return(forms)
}

#' @details \code{generateFormulasSIRIUS} uses
#'   \href{https://bio.informatik.uni-jena.de/software/sirius/}{SIRIUS} to
#'   generate chemical formulae. Similarity of measured and theoretical isotopic
#'   patterns will be used for scoring candidates. Note that \command{SIRIUS}
#'   requires availability of MS/MS data.
#'
#' @templateVar ident FALSE
#' @template sirius-args
#' 
#' @param verbose If \code{TRUE} then more output is shown in the terminal.
#'
#' @rdname formula-generation
#' @export
generateFormulasSIRIUS <- function(fGroups, MSPeakLists, relMzDev = 5, adduct = "[M+H]+", elements = "CHNOP",
                                   profile = "qtof", database = NULL, noise = NULL, cores = NULL, topMost = 100,
                                   extraOptsGeneral = NULL, extraOptsFormula = NULL, calculateFeatures = TRUE,
                                   featThreshold = 0.75, verbose = TRUE,
                                   SIRBatchSize = 0, logPath = file.path("log", "sirius_formulas"),
                                   maxProcAmount = getOption("patRoon.maxProcAmount"))
{
    ac <- checkmate::makeAssertCollection()
    checkmate::assertClass(fGroups, "featureGroups", add = ac)
    checkmate::assertClass(MSPeakLists, "MSPeakLists", add = ac)
    checkmate::assertNumber(relMzDev, lower = 0, finite = TRUE, add = ac)
    aapply(checkmate::assertString, . ~ elements + profile, fixed = list(add = ac))
    checkmate::assertString(database, null.ok = TRUE, add = ac)
    checkmate::assertNumber(noise, lower = 0, finite = TRUE, null.ok = TRUE, add = ac)
    checkmate::assertCount(cores, positive = TRUE, null.ok = TRUE, add = ac)
    checkmate::assertCount(topMost, positive = TRUE, add = ac)
    aapply(checkmate::assertCharacter, . ~ extraOptsGeneral + extraOptsFormula, null.ok = TRUE, fixed = list(add = ac))
    checkmate::assertFlag(calculateFeatures, add = ac)
    checkmate::assertNumber(featThreshold, lower = 0, finite = TRUE, null.ok = TRUE, add = ac)
    checkmate::assertFlag(verbose, add = ac)
    checkmate::assertCount(SIRBatchSize, add = ac)
    assertMultiProcArgs(logPath, maxProcAmount, add = ac)
    checkmate::reportAssertions(ac)
    
    adduct <- checkAndToAdduct(adduct)
    gNames <- names(fGroups)
    gCount <- length(fGroups)
    
    printf("Processing %d feature groups with SIRIUS...\n---\n", gCount)
    formTable <- doSIRIUS(fGroups, MSPeakLists, calculateFeatures, profile, adduct, relMzDev, elements,
                          database, noise, cores, FALSE, NULL, topMost, extraOptsGeneral, extraOptsFormula,
                          verbose, "formulasSIRIUS", processSIRIUSFormulas, NULL,
                          SIRBatchSize, logPath, maxProcAmount)
        
    if (calculateFeatures)
    {
        if (length(formTable) > 0)
        {
            formTable <- lapply(formTable, pruneList, checkZeroRows = TRUE)
            groupFormulas <- generateGroupFormulasByConsensus(formTable, featThreshold, gNames)
        }
        else
            groupFormulas <- list()
    }
    else
    {
        groupFormulas <- pruneList(formTable, checkZeroRows = TRUE)
        formTable <- list()
    }
    
    if (verbose)
    {
        printf("-------\n")
        if (calculateFeatures && length(formTable) > 0)
        {
            fCounts <- sapply(formTable, countUniqueFormulas)
            fTotCount <- sum(fCounts)
            printf("Formula statistics:\n")
            printf("%s: %d (%.1f%%)\n", names(formTable), fCounts, if (fTotCount == 0) 0 else fCounts * 100 / fTotCount)
            printf("Total: %d\n", fTotCount)
        }
        ngrp <- length(groupFormulas)
        printf("Assigned %d unique formulas to %d feature groups (%.2f%% coverage).\n", countUniqueFormulas(groupFormulas),
               ngrp, if (gCount == 0) 0 else ngrp * 100 / gCount)
    }
    
    return(formulas(formulas = groupFormulas, featureFormulas = formTable, algorithm = "sirius"))
}
