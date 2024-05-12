{-# LANGUAGE BangPatterns, CPP, GADTs, FlexibleContexts, ScopedTypeVariables #-}
-- |
-- Module    : System.Random.MWC.Distributions
-- Copyright : (c) 2012 Bryan O'Sullivan
-- License   : BSD3
--
-- Maintainer  : bos@serpentine.com
-- Stability   : experimental
-- Portability : portable
--
-- Pseudo-random number generation for non-uniform distributions.

module System.Random.MWC.Distributions
    (
    -- * Variates: non-uniformly distributed values
    -- ** Continuous distributions
      normal
    , standard
    , exponential
    , truncatedExp
    , gamma
    , chiSquare
    , beta
      -- ** Discrete distribution
    , categorical
    , logCategorical
    , geometric0
    , geometric1
    , bernoulli
    , binomial
      -- ** Multivariate
    , dirichlet
      -- * Permutations
    , uniformPermutation
    , uniformShuffle
    , uniformShuffleM
    -- * References
    -- $references
    ) where

import Prelude hiding (mapM)
import Control.Monad (liftM)
import Control.Monad.Primitive (PrimMonad, PrimState)
import Data.Bits ((.&.))
import Data.Foldable (foldl')
#if !MIN_VERSION_base(4,8,0)
import Data.Traversable (Traversable)
#endif
import Data.Traversable (mapM)
import Data.Word (Word32)
import System.Random.Stateful (StatefulGen(..),Uniform(..),UniformRange(..),uniformDoublePositive01M)
import qualified Data.Vector.Unboxed         as I
import qualified Data.Vector.Generic         as G
import qualified Data.Vector.Generic.Mutable as M
import Numeric.SpecFunctions (logFactorial)

-- Unboxed 2-tuple
data T = T {-# UNPACK #-} !Double {-# UNPACK #-} !Double


-- | Generate a normally distributed random variate with given mean
-- and standard deviation.
normal :: StatefulGen g m
       => Double                -- ^ Mean
       -> Double                -- ^ Standard deviation
       -> g
       -> m Double
{-# INLINE normal #-}
normal m s gen = do
  x <- standard gen
  return $! m + s * x

-- | Generate a normally distributed random variate with zero mean and
-- unit variance.
--
-- The implementation uses Doornik's modified ziggurat algorithm.
-- Compared to the ziggurat algorithm usually used, this is slower,
-- but generates more independent variates that pass stringent tests
-- of randomness.
standard :: StatefulGen g m => g -> m Double
{-# INLINE standard #-}
standard gen = loop
  where
    loop = do
      u  <- (subtract 1 . (*2)) `liftM` uniformDoublePositive01M gen
      ri <- uniformM gen
      let i  = fromIntegral ((ri :: Word32) .&. 127)
          bi = I.unsafeIndex blocks i
          bj = I.unsafeIndex blocks (i+1)
      case () of
        _| abs u < I.unsafeIndex ratios i -> return $! u * bi
         | i == 0                         -> normalTail (u < 0)
         | otherwise                      -> do
             let x  = u * bi
                 xx = x * x
                 d  = exp (-0.5 * (bi * bi - xx))
                 e  = exp (-0.5 * (bj * bj - xx))
             c <- uniformDoublePositive01M gen
             if e + c * (d - e) < 1
               then return x
               else loop
    normalTail neg  = tailing
      where tailing  = do
              x <- ((/rNorm) . log) `liftM` uniformDoublePositive01M gen
              y <- log              `liftM` uniformDoublePositive01M gen
              if y * (-2) < x * x
                then tailing
                else return $! if neg then x - rNorm else rNorm - x

-- Constants used by standard/normal. They are floated to the top
-- level to avoid performance regression (Bug #16) when blocks/ratios
-- are recalculated on each call to standard/normal. It's also
-- somewhat difficult to trigger reliably.
blocks :: I.Vector Double
blocks = (`I.snoc` 0) . I.cons (v/f) . I.cons rNorm . I.unfoldrN 126 go $! T rNorm f
  where
    go (T b g) = let !u = T h (exp (-0.5 * h * h))
                     h  = sqrt (-2 * log (v / b + g))
                 in Just (h, u)
    v = 9.91256303526217e-3
    f = exp (-0.5 * rNorm * rNorm)
{-# NOINLINE blocks #-}

rNorm :: Double
rNorm = 3.442619855899

ratios :: I.Vector Double
ratios = I.zipWith (/) (I.tail blocks) blocks
{-# NOINLINE ratios #-}



-- | Generate an exponentially distributed random variate.
exponential :: StatefulGen g m
            => Double            -- ^ Scale parameter
            -> g                 -- ^ Generator
            -> m Double
{-# INLINE exponential #-}
exponential b gen = do
  x <- uniformDoublePositive01M gen
  return $! - log x / b


-- | Generate truncated exponentially distributed random variate.
truncatedExp :: StatefulGen g m
             => Double            -- ^ Scale parameter
             -> (Double,Double)   -- ^ Range to which distribution is
                                  --   truncated. Values may be negative.
             -> g                 -- ^ Generator.
             -> m Double
{-# INLINE truncatedExp #-}
truncatedExp scale (a,b) gen = do
  -- We shift a to 0 and then generate distribution truncated to [0,b-a]
  -- It's easier
  let delta = b - a
  p <- uniformDoublePositive01M gen
  return $! a - log ( (1 - p) + p*exp(-scale*delta)) / scale

-- | Random variate generator for gamma distribution.
gamma :: (StatefulGen g m)
      => Double                 -- ^ Shape parameter
      -> Double                 -- ^ Scale parameter
      -> g                      -- ^ Generator
      -> m Double
{-# INLINE gamma #-}
gamma a b gen
  | a <= 0    = pkgError "gamma" "negative alpha parameter"
  | otherwise = mainloop
    where
      mainloop = do
        T x v <- innerloop
        u     <- uniformDoublePositive01M gen
        let cont =  u > 1 - 0.331 * sqr (sqr x)
                 && log u > 0.5 * sqr x + a1 * (1 - v + log v) -- Rarely evaluated
        case () of
          _| cont      -> mainloop
           | a >= 1    -> return $! a1 * v * b
           | otherwise -> do y <- uniformDoublePositive01M gen
                             return $! y ** (1 / a) * a1 * v * b
      -- inner loop
      innerloop = do
        x <- standard gen
        case 1 + a2*x of
          v | v <= 0    -> innerloop
            | otherwise -> return $! T x (v*v*v)
      -- constants
      a' = if a < 1 then a + 1 else a
      a1 = a' - 1/3
      a2 = 1 / sqrt(9 * a1)


-- | Random variate generator for the chi square distribution.
chiSquare :: StatefulGen g m
          => Int                -- ^ Number of degrees of freedom
          -> g                  -- ^ Generator
          -> m Double
{-# INLINE chiSquare #-}
chiSquare n gen
  | n <= 0    = pkgError "chiSquare" "number of degrees of freedom must be positive"
  | otherwise = do x <- gamma (0.5 * fromIntegral n) 1 gen
                   return $! 2 * x

-- | Random variate generator for the geometric distribution,
-- computing the number of failures before success. Distribution's
-- support is [0..].
geometric0 :: StatefulGen g m
           => Double            -- ^ /p/ success probability lies in (0,1]
           -> g                 -- ^ Generator
           -> m Int
{-# INLINE geometric0 #-}
geometric0 p gen
  | p == 1          = return 0
  | p >  0 && p < 1 = do q <- uniformDoublePositive01M gen
                         -- FIXME: We want to use log1p here but it will
                         --        introduce dependency on math-functions.
                         return $! floor $ log q / log (1 - p)
  | otherwise       = pkgError "geometric0" "probability out of [0,1] range"

-- | Random variate generator for geometric distribution for number of
-- trials. Distribution's support is [1..] (i.e. just 'geometric0'
-- shifted by 1).
geometric1 :: StatefulGen g m
           => Double            -- ^ /p/ success probability lies in (0,1]
           -> g                 -- ^ Generator
           -> m Int
{-# INLINE geometric1 #-}
geometric1 p gen = do n <- geometric0 p gen
                      return $! n + 1

-- | Random variate generator for Beta distribution
beta :: StatefulGen g m
     => Double            -- ^ alpha (>0)
     -> Double            -- ^ beta  (>0)
     -> g                 -- ^ Generator
     -> m Double
{-# INLINE beta #-}
beta a b gen = do
  x <- gamma a 1 gen
  y <- gamma b 1 gen
  return $! x / (x+y)

-- | Random variate generator for Dirichlet distribution
dirichlet :: (StatefulGen g m, Traversable t)
          => t Double          -- ^ container of parameters
          -> g                 -- ^ Generator
          -> m (t Double)
{-# INLINE dirichlet #-}
dirichlet t gen = do
  t' <- mapM (\x -> gamma x 1 gen) t
  let total = foldl' (+) 0 t'
  return $ fmap (/total) t'

-- | Random variate generator for Bernoulli distribution
bernoulli :: StatefulGen g m
          => Double            -- ^ Probability of success (returning True)
          -> g                 -- ^ Generator
          -> m Bool
{-# INLINE bernoulli #-}
bernoulli p gen = (<p) `liftM` uniformDoublePositive01M gen

-- | Random variate generator for categorical distribution.
--
--   Note that if you need to generate a lot of variates functions
--   "System.Random.MWC.CondensedTable" will offer better
--   performance.  If only few is needed this function will faster
--   since it avoids costs of setting up table.
categorical :: (StatefulGen g m, G.Vector v Double)
            => v Double          -- ^ List of weights [>0]
            -> g                 -- ^ Generator
            -> m Int
{-# INLINE categorical #-}
categorical v gen
    | G.null v = pkgError "categorical" "empty weights!"
    | otherwise = do
        let cv  = G.scanl1' (+) v
        p <- (G.last cv *) `liftM` uniformDoublePositive01M gen
        return $! case G.findIndex (>=p) cv of
                    Just i  -> i
                    Nothing -> pkgError "categorical" "bad weights!"

-- | Random variate generator for categorical distribution where the
--   weights are in the log domain. It's implemented in terms of
--   'categorical'.
logCategorical :: (StatefulGen g m, G.Vector v Double)
               => v Double          -- ^ List of logarithms of weights
               -> g                 -- ^ Generator
               -> m Int
{-# INLINE logCategorical #-}
logCategorical v gen
  | G.null v  = pkgError "logCategorical" "empty weights!"
  | otherwise = categorical (G.map (exp . subtract m) v) gen
  where
    m = G.maximum v

-- | Random variate generator for uniformly distributed permutations.
--   It returns random permutation of vector /[0 .. n-1]/.
--
--   This is the Fisher-Yates shuffle
uniformPermutation :: forall g m v. (StatefulGen g m, PrimMonad m, G.Vector v Int)
                   => Int
                   -> g
                   -> m (v Int)
{-# INLINE uniformPermutation #-}
uniformPermutation n gen
  | n < 0     = pkgError "uniformPermutation" "size must be >=0"
  | otherwise = uniformShuffle (G.generate n id :: v Int) gen

-- | Random variate generator for a uniformly distributed shuffle (all
--   shuffles are equiprobable) of a vector. It uses Fisher-Yates
--   shuffle algorithm.
uniformShuffle :: (StatefulGen g m, PrimMonad m, G.Vector v a)
               => v a
               -> g
               -> m (v a)
{-# INLINE uniformShuffle #-}
uniformShuffle vec gen
  | G.length vec <= 1 = return vec
  | otherwise         = do
      mvec <- G.thaw vec
      uniformShuffleM mvec gen
      G.unsafeFreeze mvec

-- | In-place uniformly distributed shuffle (all shuffles are
--   equiprobable)of a vector.
uniformShuffleM :: (StatefulGen g m, PrimMonad m, M.MVector v a)
                => v (PrimState m) a
                -> g
                -> m ()
{-# INLINE uniformShuffleM #-}
uniformShuffleM vec gen
  | M.length vec <= 1 = return ()
  | otherwise         = loop 0
  where
    n   = M.length vec
    lst = n-1
    loop i | i == lst  = return ()
           | otherwise = do j <- uniformRM (i,lst) gen
                            M.unsafeSwap vec i j
                            loop (i+1)


sqr :: Double -> Double
sqr x = x * x
{-# INLINE sqr #-}

pkgError :: String -> String -> a
pkgError func msg = error $ "System.Random.MWC.Distributions." ++ func ++
                            ": " ++ msg

-- $references
--
-- * Doornik, J.A. (2005) An improved ziggurat method to generate
--   normal random samples. Mimeo, Nuffield College, University of
--   Oxford.  <http://www.doornik.com/research/ziggurat.pdf>
--
-- * Thomas, D.B.; Leong, P.G.W.; Luk, W.; Villasenor, J.D.
--   (2007). Gaussian random number generators.
--   /ACM Computing Surveys/ 39(4).
--   <http://www.cse.cuhk.edu.hk/~phwl/mt/public/archives/papers/grng_acmcs07.pdf>
--
-- * Kachitvichyanukul, V. and Schmeiser, B. W.  Binomial Random
--   Variate Generation.  Communications of the ACM, 31, 2 (February,
--   1988) 216. <https://dl.acm.org/doi/pdf/10.1145/42372.42381>

-- | Random variate generator for Binomial distribution
--
-- The probability of getting exactly k successes in n trials is
-- given by the probability mass function:
--
-- \[
-- f(k;n,p) = \Pr(X = k) = \binom n k  p^k(1-p)^{n-k}
-- \]
binomial :: forall g m . StatefulGen g m
         => Int               -- ^ Number of trials
         -> Double            -- ^ Probability of success (returning True)
         -> g                 -- ^ Generator
         -> m Int
{-# INLINE binomial #-}
binomial nTrials prob gen
  | nTrials <= 0             = pkgError "binomial" "number of trials must be positive"
  | prob < 0.0 || prob > 1.0 = pkgError "binomial" "probability must be >= 0 and <= 1"
  | prob == 0.0 = return 0
  | prob == 1.0 = return nTrials
  | otherwise = do let (p', flipped) = if prob > 0.5 then (1.0 - prob, True) else (prob, False)
                   ix <- if fromIntegral nTrials * p' < bInvThreshold
                         then binomialInv nTrials p' gen
                         else binomialTPE nTrials p' gen
                   if flipped
                     then return $ nTrials - ix
                     else return ix

  where
    binomialTPE n p g =
      let q    = 1 - p
          np   = fromIntegral n * p
          ffm  = np + p
          bigM = floor ffm
          -- Half integer mean (tip of triangle)
          xm   = fromIntegral bigM + 0.5
          npq  = np * q

          -- p1: the distance to the left and right edges of the triangle
          -- region below the target distribution; since height=1, also:
          -- area of region (half base * height)
          p1 = fromIntegral (floor (2.195 * sqrt npq - 4.6 * q) :: Int) + 0.5
          -- Left edge of triangle
          xl = xm - p1
          -- Right edge of triangle
          xr = xm + p1
          c  = 0.134 + 20.5 / (15.3 + fromIntegral bigM)
          -- p1 + area of parallelogram region
          p2 = p1 * (1.0 + c + c)
          al = (ffm - xl) / (ffm - xl * p)
          lambdaL = al * (1.0 + 0.5 * al)
          ar = (xr - ffm) / (xr * q)
          lambdaR = ar * (1.0 + 0.5 * ar)

          -- p2 + area of left tail
          p3 = p2 + c / lambdaL
          -- p3 + area of right tail
          p4 = p3 + c / lambdaR

          -- Acceptance / rejection comparison
          step5 :: Int -> Double -> m Int
          step5 ix v
            | var <= accept = return $ if p > 0 then ix else n - ix
            | otherwise     = hh
            where
              var = log v
              accept = logFactorial bigM + logFactorial (n - bigM) -
                       logFactorial ix - logFactorial (n - ix) +
                       fromIntegral (ix - bigM) * log (p / q)

          h :: Double -> Double -> m Int
          h u v | -- Triangular region
                  u <= p1 = return $ floor $ xm - p1 * v + u

                  -- Parallelogram region
                | u <= p2 = do let x = xl + (u - p1) / c
                                   w = v * c + 1.0 - abs (x - xm) / p1
                               if w > 1 || w <= 0
                                then hh
                                else do let ix = floor x
                                        step5 ix w

                  -- Left tail
                | u <= p3 = do let ix = floor $ xl + log v / lambdaL
                               if ix < 0
                                 then hh
                                 else do let w = v * (u - p2) * lambdaL
                                         step5 ix w

                  -- Right tail
                | otherwise = do let ix = floor $ xr - log v / lambdaL
                                 if ix > 0 && ix > n
                                   then hh
                                   else do let w = v * (u - p3) * lambdaR
                                           step5 ix w

          hh = do
            u <- uniformRM (0.0, p4) g
            v <- uniformDoublePositive01M g
            h u v

      in hh

    binomialInv :: StatefulGen g m => Int -> Double -> g -> m Int
    binomialInv n p g = do
      let q = 1 - p
          s = p / q
          a = fromIntegral (n + 1) * s
          r = q^n
          f (rPrev, uPrev, xPrev) = (rNew, uNew, xNew)
            where
              uNew = uPrev - rPrev
              xNew = xPrev + 1
              rNew = rPrev * ((a / fromIntegral xNew) - s)
      u <- uniformDoublePositive01M g
      let (_, _, x) = until (\(t, v, _) -> v <= t) f (r, u, 0) in return x

    -- Threshold for preferring the BINV algorithm / inverse cdf
    -- logic. The paper suggests 10, Ranlib uses 30, R uses 30, Rust uses
    -- 10 and GSL uses 14.
    bInvThreshold :: Double
    bInvThreshold = 10
