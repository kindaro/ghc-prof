{-# LANGUAGE CPP #-}
{-# LANGUAGE ViewPatterns #-}
module Main where
import Control.Applicative
import Control.Monad
import Data.Foldable
import Data.Monoid
import Data.Traversable
import System.Directory
import System.FilePath
import System.IO
import Prelude

import System.IO.Temp
import System.Process
import Test.Tasty
import Test.Tasty.HUnit
import qualified Data.Attoparsec.Text.Lazy as ATL
import qualified Data.Set as Set
import qualified Data.Text.Lazy.IO as TL

import GHC.Prof

#if !MIN_VERSION_directory(1, 2, 3)
import Control.Exception
#endif

main :: IO ()
main = withSystemTempDirectory "test" $ \dir -> withCurrentDirectory dir $
  defaultMain $ testCaseSteps "Regression tests" $ \step -> do
    step "Generating profiling reports"
    profiles <- generateProfiles
    for_ profiles $ \prof -> do
      step $ "Parsing " ++ prof
      assertProfile prof

generateProfiles :: IO [FilePath]
generateProfiles = do
  withFile "hello.hs" WriteMode $ \h ->
    hPutStrLn h $ unlines
      [ "import Control.Exception"
      , "main = evaluate $ fib 100000"
      , "fib n = fibs !! n"
      , "fibs = 0:1:zipWith (+) fibs (tail fibs)"
      ]
  void $ readProcess "ghc" ["-prof", "-rtsopts", "-fforce-recomp", "hello.hs"] ""
  for profilingFlags $ \(name, flag) -> do
    void $ readProcess "./hello" ["+RTS", flag, "-RTS"] ""
    let profName = "hello" <.> name <.> "prof"
    renameFile "hello.prof" profName
    return profName

profilingFlags :: [(String, String)]
profilingFlags =
  [ ("standard", "-p")
  , ("detailed", "-P")
  , ("full", "-pa")
  ]

assertProfile :: FilePath -> Assertion
assertProfile path = do
  text <- TL.readFile path
  case ATL.parse profile text of
    ATL.Done _ prof -> do
      let actual = Set.fromList $ map Similar $ aggregatedCostCentres prof
          expected = Set.fromList $ map Similar $ profileTopCostCentres prof
      assertBool
        ("Missing cost centre(s): " ++ show (Set.difference expected actual)) $
          Set.isSubsetOf expected actual
    ATL.Fail _ _ reason -> assertFailure reason

newtype Similar = Similar AggregatedCostCentre

instance Show Similar where
  show (Similar a) = show a

instance Eq Similar where
  Similar a == Similar b =
    aggregatedCostCentreName a == aggregatedCostCentreName b
    && aggregatedCostCentreModule a == aggregatedCostCentreModule b
    && aggregatedCostCentreTime a == aggregatedCostCentreTime b
    && aggregatedCostCentreAlloc a == aggregatedCostCentreAlloc b
    && aggregatedCostCentreTicks a == aggregatedCostCentreTicks b
    && aggregatedCostCentreBytes a == aggregatedCostCentreBytes b


instance Ord Similar where
  compare (Similar a) (Similar b) =
    compare (aggregatedCostCentreName a) (aggregatedCostCentreName b)
    <> compare (aggregatedCostCentreModule a) (aggregatedCostCentreModule b)
    <> compare (aggregatedCostCentreTime a) (aggregatedCostCentreTime b)
    <> compare (aggregatedCostCentreAlloc a) (aggregatedCostCentreAlloc b)
    <> compare (aggregatedCostCentreTicks a) (aggregatedCostCentreTicks b)
    <> compare (aggregatedCostCentreBytes a) (aggregatedCostCentreBytes b)

#if !MIN_VERSION_directory(1, 2, 3)
withCurrentDirectory :: FilePath -> IO a -> IO a
withCurrentDirectory dir io = bracket
  (getCurrentDirectory <* setCurrentDirectory dir)
  (setCurrentDirectory)
  (const io)
#endif
