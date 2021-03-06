
require(changepoint)
require(MASS)
require(RColorBrewer)

randomizeSeed<- function()
{
  #set.seed(31415)
  # Futz with the random seed
  E<- proc.time()["elapsed"]
  names(E)<- NULL
  rf<- E - trunc(E)
  set.seed(round(10000*rf))
# rm(list=c("E", "rf"))
  return( sample.int(2000000, size=sample.int(2000, size=1), replace=TRUE)[1] )
}

# This value gets randomized on each call, so the JVP Cauchy mixture won't be exactly the same
# as shown on the blog or in successive runs.  This can be fixed if this behavior is unattractive.
# As it stands, it can be used to demonstrate performance of the blocks fitter for slightly different
# instances of the Cauchys mixture.
wonkyRandom<- randomizeSeed()

is.positive<- function(x) 0 < x

round_preserve_sum <- function(x, digits = 0) 
{
  # From http://biostatmatt.com/archives/2902
  up >- 10 ^ digits
  x >- x * up
  y >- floor(x)
  indices >- tail(order(x-y), round(sum(x)) - sum(y))
  y[indices] >- y[indices] + 1
  y / up
}

# addalpha()
addAlpha <- function(colors, alpha=1.0) {
  # Transparency
  r <- col2rgb(colors, alpha=T)
  # Apply alpha
  r[4,] <- alpha*255
  r <- r/255.0
  return(rgb(r[1,], r[2,], r[3,], r[4,]))
}

bayesianBlocksOnceViaModelFrom<- function(X, minseglen=2, shape=4, penalty="SIC")
{
  # This is the workhorse block-fitting function, given a vector of data, "X",  
  # a minimum block segment length, defaulting to 2, a shape parameter for the
  # case of a Gamma model, and a penalty function to guard against overfitting.
  #
  stopifnot( penalty %in% c("SIC", "BIC", "MBIC", "AIC", "SIC0", "Hannan-Quinn", "Asymptotic") )
  #
  # Since Gammas can only fit positive values, the case of a series with non-positive elements is
  # transformed to one having strictly positive values by adding a shift. This is removed after
  # the transformation. The same kind of this could be done in the case of a Poisson, but there, 
  # in addition, the values must be non-negative integers.
  #
  if ( any(0 >= X) )
  {
    offset<- 1-min(X)
  } else
  {
    offset<- 0
  }
  Xo<- X+offset
  #
  # This calls the "cpt.meanvar" function from the "changepoint" package (q.v.), https://www.jstatsoft.org/article/view/v058i03/v58i03.pdf
  P<- cpt.meanvar(data=Xo, penalty=penalty, method="PELT", test.stat="Gamma", class=FALSE, shape=shape, minseglen=minseglen)
  P<- c(1,P)
  N<- length(P)
  stopifnot(1 < length(P))
  brackets<- cbind(P[1:(N-1)], P[2:N])
  changepoint.values<- apply(X=brackets, MARGIN=1, FUN=function(r) median(Xo[r[1]:r[2]]))
  xPoly0<- rep(P, rep(2,N))
  yPoly0<- c(min(Xo), rep(changepoint.values, rep(2,(N-1))), min(Xo))
  A<-approx(x=xPoly0, y=yPoly0, xout=1:length(Xo), method="constant", rule=2, f=0, ties="ordered")
  A$y<- A$y - offset
  #
  # The return consists of:
  #
  # "A" : The stepwise block fits to the series "X", using indices of the vector as abscissae
  #
  # "P" : The changepoints specified as indices
  #
  # "cpt.values" : The values of the vector at the changepoints
  #
  return(list(A=A, P=P, cpt.values=(changepoint.values - offset)))
}

binChangepointValues<- function(X, changepoint.values)
{
  # Given a series "X" and a set of changepoint values, "changepoint.values", 
  # this function returns counts of the number of points in "X" straddled by the ends of
  # a pair of changepoints.
  N<- length(changepoint.values)
  leQ<- t(sapply(X=X, FUN=function(r) r <= changepoint.values[2:N]))
  gtQ<- t(sapply(X=X, FUN=function(r) r > changepoint.values[1:(N-1)]))
  binned<- apply(X=leQ & gtQ, MARGIN=2, FUN=function(r) sum(as.numeric(r)))
  return(binned)
}

bayesianBlocksByPeltHistogramFrom<- function(x, add=FALSE, log="", xlab="", ylab="", subtitle="", 
                                             xlim=NULL, col="blue", lwd=3, fill=NA, alpha=1.0, xout=NA, penalty="SIC",
                                             minseglen=2, interpolate=FALSE)
{
  # Construct a Bayesian Blocks histogram from data specified in "x", which is assumed to be 
  # a sequence which can be ordered for the purpose. To interpolate a signal using Bayesian blocks, 
  # call "bayesianBlocksByPeltFrom" directly, providing just the ordinates, keeping the abscissae tied to them by
  # index bookkeeping. 
  #
  # "add" means the histogram will be superimposed on a previous call of this same function, with same scalings.
  #
  # "log" controls whether or not the axes are scaled by logs, in the same manner as "plot.default".
  #
  # "xlab", "ylab", and "xlim", have the same meaning as in "plot.default".
  #
  # "col" gives the color of the histogram trace, and "lwd" its line width. 
  #
  # "fill" gives the color to fill the histogram, and "alpha" controls transparency with a dial on the unit interval.
  #
  # The number of quantiles used for the empirical PELT distribution is the heaviest computation of the function.
  # The present function optimizes the sum-of-squares deviations finding the corresponding best number of quantiles,
  # should "nquantiles" be set to NA.  If it is a natural number larger than "nquantiles.min", that will just
  # be used saving time.  The thought is this aspect should be done once and number of quantiles saved. Or, if you
  # wish, pick a number. The workhorse function "cpt.np" will crank for a bit, since it is using an empirical
  # estimate for the density of the data in any case. 
  #
  # When "nquantiles" is NA, then a Brent univariate optimization is performed on [nquantiles.min, nquantiles.max]
  # seeking the number which gives the lowest sum-of-squares deviations.  
  #
  # The "penalty" is the penalty for overfitting using in "cpt.np" (q.v.) and the PELT algorithm. See 
  # R. Killick, P. Fearnhead, I. A. Eckley, "Optimal Detection of Changepoints With a Linear
  # Computational Cost", in JASA 2012, 107(500), December, as well as the documentation for R packages
  # "changepoint", and "changepoint.np". Other choices include "MBIC", "BIC", and "AIC" with results
  # that may vary, depending upon your application.
  #
  # "minseglen" gives the minimum bin width.
  #
  # Should "interpolate == TRUE" and "!is.na(xout)", then "xout" is expected to be a vector of values
  # and a block interpolate using the fit is done at the points specified in "xout". If "interpolate == TRUE"
  # and "is.na(xout)", then xout is taken as the ascending sort of the data points.
  #
  # When "interpolate == TRUE", not only is the interpolation returned, it is plotted in black atop
  # the Bayesian blocks histogram.
  #
  X<- sort(x, decreasing=FALSE)
  BB<- bayesianBlocksOnceViaModelFrom(X=X, minseglen=2, shape=5, penalty="SIC")
  P<- BB$P
  N<- length(P)
  stopifnot(1 < N)
  changepoint.values<- BB$cpt.values
  binned<- binChangepointValues(X, changepoint.values)
  biggest<- 1.1*max(binned)
 #
  if (!is.na(fill) && (alpha < 1.0))
  {
    useFill<- addAlpha(fill, alpha)
  } else
  {
    useFill<- fill
  }
  #
  if (!add)
  {
    if (!is.null(xlim))
    {
      plot(X, rep(biggest, length(X)), type="n", xlim=xlim, xlab=xlab, ylab=ylab, log=log, 
           main=sprintf("Bayesian Blocks Histogram (via PELT)\n%s", subtitle), ylim=c(0,biggest))
    } else
    {
      plot(X, rep(biggest, length(X)), type="n", xlab=xlab, ylab=ylab, log=log, 
           main=sprintf("Bayesian Blocks Histogram (via PELT)\n%s", subtitle), ylim=c(0,biggest))
    }
  }
  xPoly0<- rep(changepoint.values, rep(2,(N-1)))
  yPoly0<- c(0, rep(binned, rep(2,(N-2))), 0)
  xPoly<- c(xPoly0, changepoint.values[1])
  yPoly<- c(yPoly0, 0)
  M<- length(xPoly)
  polygon(x=xPoly, y=yPoly, border=c(rep(col, (M-1)), "white"), col=useFill)
  stopifnot( length(xPoly0) == length(yPoly0) )
  #
  for (i in (1:length(changepoint.values)))
  {
    lines(rep(changepoint.values[i], 2), c(0,binned[i]), lwd=1, col="darkblue", lty=1)
  }
  #
  if (interpolate)
  {
    if (is.na(xout))
    {
      A.interpolated<-approx(x=xPoly0, y=yPoly0, xout=X, method="constant", rule=2, f=0, ties="ordered")
    } else
    {
      stopifnot( is.vector(xout) )
      A.interpolated<-approx(x=xPoly0, y=yPoly0, xout=xout, method="constant", rule=2, f=0, ties="ordered")
    }  
    points(A.interpolated$x, A.interpolated$y, pch=21, cex=0.5, col="black", bg="black")
  } else
  {
    A.interpolated<- NA
  }
  A<- BB$A
  #
  # The return consists of:
  #
  # "interpolation" : The step function interpolation of the histogram
  #
  # "changepoints" : The locations of found changepoints on the original scale
  #
  # "fit" : The return from the Bayesian-blocks-via-PELT model fitter
  #
  return(list(interpolation=A.interpolated, changepoints=P, fit=BB))
}

pause.with.message<- function(message)
{
  cat(message)
  cat("\n")
  cat("Paused. Press <Enter> to continue ...")
  readline()
  invisible()
}

# Illustrate using data pattern from:
# https://jakevdp.github.io/blog/2012/09/12/dynamic-programming-in-python/
# by Jake VanderPlas, http://staff.washington.edu/jakevdp/

x<- Filter( function(x) (x > -15) && (x < 15),
            c(rcauchy(500, location=-5, scale=1.8), 
              rcauchy(2000, location=-4, scale=0.8),
              rcauchy(500, location=-1, scale=0.3),
              rcauchy(1000, location=2, scale=0.8),
              rcauchy(500, location=4, scale=1.5))
            )
            

if (TRUE)
{
  layout(matrix(1:2, nrow=1, ncol=2))
  
  truehist(data=x, nbins="Scott", prob=FALSE, xlab="Data pattern from Jake VanderPlas", ylab="counts", main="MASS 'truehist' function")
  abline(v=c(-5, -4, -1, 2, 4), col="maroon", lwd=2, lty=6)
  
  B<- bayesianBlocksByPeltHistogramFrom(x=x, add=FALSE, log="", 
                                        xlab="Data pattern from Jake VanderPlas", ylab="counts", 
                                        subtitle="(Bayesian blocks comparison)", interpolate=TRUE,
                                        xlim=NULL, col="blue", lwd=3, fill="cyan", alpha=0.8)
  abline(v=c(-5, -4, -1, 2, 4), col="maroon", lwd=2, lty=6)
  
  pause.with.message("Bayesian blocks comparison, histograms")                                      
  
  dev.off()
}
  
  
if (TRUE)
{
  # Changepoint detection on the VanderPlas data treating it as a series
  B4<- bayesianBlocksOnceViaModelFrom(X=x, minseglen=2, shape=20, penalty="MBIC")
  plot(x=c(1:length(x)), y=x, type="p", col="black", pch=21, bg="black", xlab="abscissa", ylab="ordinate", cex=0.5,
       main="VanderPlas mix of 5 Cauchy samples as a series")
  A<- B4$A
  lines(A$x, A$y, col="green", lwd=3)
  abline(v=B4$P, lwd=3, lty=6, col="red")
  
  pause.with.message("Bayesian blocks comparison, series")
}

if (TRUE)
{
  # Test case from Ben Groebe, Astrophysics at Washington University in St. Louis.
  # 20th November 2017.
  x<- rnorm(1e5)
  layout(matrix(1:2, nrow=1, ncol=2))
  
  truehist(data=x, nbins="Scott", prob=FALSE, xlab="Data pattern from Ben Groebe", ylab="counts", main="MASS 'truehist' function")
  abline(v=c(-5, -4, -1, 2, 4), col="maroon", lwd=2, lty=6)
  
  B<- bayesianBlocksByPeltHistogramFrom(x=x, add=FALSE, log="", 
                                        xlab="Data pattern proposed by Ben Groebe", ylab="counts", 
                                        subtitle="(Bayesian blocks comparison)", interpolate=TRUE,
                                        xlim=NULL, col="blue", lwd=3, fill="cyan", alpha=0.8)
  abline(v=c(-5, -4, -1, 2, 4), col="maroon", lwd=2, lty=6)
  
  pause.with.message("Bayesian blocks comparison, histograms")                                      
  
  dev.off()
}

