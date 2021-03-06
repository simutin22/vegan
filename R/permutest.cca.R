permutest <- function(x, ...)
    UseMethod("permutest")

permutest.default <- function(x, ...)
    stop("No default permutation test defined")

`permutest.cca` <-
    function (x, permutations = how(nperm=99),
              model = c("reduced", "direct", "full"), first = FALSE,
              strata = NULL, parallel = getOption("mc.cores") , C = TRUE, ...)
{
    ## do something sensible with insensible input (no constraints)
    if (is.null(x$CCA)) {
        sol <- list(call = match.call(), testcall = x$call, model = NA,
                    F.0 = NA, F.perm = NA, chi = c(0, x$CA$tot.chi),
                    num = 0, den = x$CA$tot.chi,
                    df = c(0, nrow(x$CA$u) - max(x$pCCA$rank,0) - 1),
                    nperm = 0, method = x$method, first = FALSE,
                    Random.seed = NA)
        class(sol) <- "permutest.cca"
        return(sol)
    }
    model <- match.arg(model)
    ## special cases
    isCCA <- !inherits(x, "rda")    # weighting
    isPartial <- !is.null(x$pCCA)   # handle conditions
    ## first eigenvalue cannot be analysed with capscale which had
    ## discarded imaginary values: cast to old before evaluating isDB
    if (first && inherits(x, "capscale"))
        x <- oldCapscale(x)
    isDB <- inherits(x, c("capscale", "dbrda")) &&
        !inherits(x, "oldcapscale")  # distance-based & new design
    ## Function to get the F statistics in one loop
    getF <- function (indx, ...)
    {
        getEV <- function(x, isDB=FALSE)
        {
            if (isDB)
                sum(diag(x))
            else
                sum(x*x)
        }
        if (!is.matrix(indx))
            dim(indx) <- c(1, length(indx))
        R <- nrow(indx)
        mat <- matrix(0, nrow = R, ncol = 3)
        for (i in seq_len(R)) {
            take <- indx[i,]
            if (isDB)
                Y <- E[take, take]
            else
                Y <- E[take, ]
            if (isPartial) {
                Y <- qr.resid(QZ, Y)
                if (isDB)
                    Y <- qr.resid(QZ, t(Y))
            }
            tmp <- qr.fitted(Q, Y)
            if (first) {
                if (isDB) {
                    tmp <- qr.fitted(Q, t(tmp)) # eigen needs symmetric tmp
                    cca.ev <- eigen(tmp, symmetric = TRUE)$values[1]
                } else
                    cca.ev <- La.svd(tmp, nv = 0, nu = 0)$d[1]^2
            } else
                cca.ev <- getEV(tmp, isDB)
            if (isPartial || first) {
                tmp <- qr.resid(Q, Y)
                ca.ev <- getEV(tmp, isDB)
            }
            else ca.ev <- Chi.tot - cca.ev
            mat[i,] <- cbind(cca.ev, ca.ev, (cca.ev/q)/(ca.ev/r))
        }
        mat
    }
    ## end getF()
    CgetF <- function(indx, ...)
    {
        if (!is.matrix(indx))
            indx <- matrix(indx, nrow=1)
        out <- .Call("do_getF", indx, E, Q, QZ, first, isPartial, isDB)
        if (!isPartial && !first)
            out[,2] <- Chi.tot - out[,1]
        out <- cbind(out, (out[,1]/q)/(out[,2]/r))
        out
    }
    if (C)
        getF <- CgetF

    if (first) {
        Chi.z <- x$CCA$eig[1]
        q <- 1
    }
    else {
        Chi.z <- x$CCA$tot.chi
        names(Chi.z) <- "Model"
        q <- x$CCA$qrank
    }
    ## Set up
    Chi.xz <- x$CA$tot.chi
    names(Chi.xz) <- "Residual"
    r <- nobs(x) - x$CCA$QR$rank - 1
    if (model == "full")
        Chi.tot <- Chi.xz
    else Chi.tot <- Chi.z + Chi.xz
    if (!isCCA && !isDB)
        Chi.tot <- Chi.tot * (nrow(x$CCA$Xbar) - 1)
    F.0 <- (Chi.z/q)/(Chi.xz/r)
    Q <- x$CCA$QR
    if (isPartial) {
        Y.Z <- if (isDB) x$pCCA$G else x$pCCA$Fit
        QZ <- x$pCCA$QR
    } else {
        QZ <- NULL
    }
    if (model == "reduced" || model == "direct")
        E <- if (isDB) x$CCA$G else x$CCA$Xbar
    else E <-
        if (isDB) stop(gettextf("%s cannot be used with 'full' model"), x$method)
        else x$CA$Xbar
    if (isPartial && model == "direct")
        E <- if (isDB) x$pCCA$G else E + Y.Z
    ## Save dimensions
    N <- nrow(E)
    permutations <- getPermuteMatrix(permutations, N, strata = strata)
    nperm <- nrow(permutations)
    ## Parallel processing (similar as in oecosimu)
    if (is.null(parallel))
        parallel <- 1
    hasClus <- inherits(parallel, "cluster")
    if (hasClus || parallel > 1) {
        if(.Platform$OS.type == "unix" && !hasClus) {
            tmp <- do.call(rbind,
                           mclapply(1:nperm,
                                    function(i) getF(permutations[i,]),
                                    mc.cores = parallel))
        } else {
            ## if hasClus, do not set up and stop a temporary cluster
            if (!hasClus) {
                parallel <- makeCluster(parallel)
            }
            tmp <- parRapply(parallel, permutations, function(i) getF(i))
            tmp <- matrix(tmp, ncol=3, byrow=TRUE)
            if (!hasClus)
                stopCluster(parallel)
        }
    } else {
        tmp <- getF(permutations)
    }
    num <- tmp[,1]
    den <- tmp[,2]
    F.perm <- tmp[,3]
    Call <- match.call()
    Call[[1]] <- as.name("permutest")
    sol <- list(call = Call, testcall = x$call, model = model,
                F.0 = F.0, F.perm = F.perm,  chi = c(Chi.z, Chi.xz),
                num = num, den = den, df = c(q, r), nperm = nperm,
                method = x$method, first = first)
    sol$Random.seed <- attr(permutations, "seed")
    sol$control <- attr(permutations, "control")
    if (!missing(strata)) {
        sol$strata <- deparse(substitute(strata))
        sol$stratum.values <- strata
    }
    class(sol) <- "permutest.cca"
    sol
}
