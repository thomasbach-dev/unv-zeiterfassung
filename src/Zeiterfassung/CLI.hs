module Zeiterfassung.CLI
  ( cliMain,
    getRedmineConfiguration,
  )
where

import           Control.Monad                (forM_, when)
import           Data.Aeson                   (eitherDecodeFileStrict)
import           Data.List                    (sortOn)
import qualified Data.Text                    as T
import qualified Data.Text.IO                 as TIO
import           Data.Time                    (Day, timeToDaysAndTimeOfDay)
import           Network.HTTP.Simple          (parseRequest)
import           Options.Applicative
    (Mod, OptionFields, Parser, ParserInfo, argument, auto, command, execParser, fullDesc, help,
    helper, info, long, metavar, option, optional, progDesc, short, showDefault, str, subparser,
    switch, value, (<**>))
import           System.Environment           (lookupEnv)
import           System.Exit                  (die)
import           System.Log.Logger
    (Priority (INFO), debugM, infoM, rootLoggerName, setLevel, updateGlobalLogger)
import           Zeiterfassung.Parser
import           Zeiterfassung.Redmine
import           Zeiterfassung.Representation

moduleLogger :: String
moduleLogger = "Zeiterfassung.CLI"

data MainArgs = MainArgs
  { logLevel    :: Priority,
    mainCommand :: MainCommand
  }
  deriving (Eq, Show)

data MainCommand
  = ToRedmine ToRedmineArgs
  | GetRedmineCommand GetRedmineCommandArgs
  deriving (Eq, Show)

cliMain :: IO ()
cliMain = do
  args <- execParser mainParser
  updateGlobalLogger rootLoggerName (setLevel args.logLevel)
  debugM "CLI.cliMain" $ "Parsed command line args: " <> show args
  dispatchToCommand (mainCommand args)

dispatchToCommand :: MainCommand -> IO ()
dispatchToCommand (ToRedmine args)         = toRedmineMain args
dispatchToCommand (GetRedmineCommand args) = getRedmineMain args

mainParser :: ParserInfo MainArgs
mainParser =
  info
    (mainArgsParser <**> helper)
    ( fullDesc
        <> progDesc "Do various things around time tracking"
    )
  where
    mainArgsParser =
      MainArgs
        <$> logLevelParser
        <*> mainCommandParser
    logLevelParser =
      option
        auto
        ( long "log-level"
            <> help "Set the log level (DEBUG, INFO, WARNING, ERROR, CRITICAL)"
            <> short 'l'
            <> metavar "LEVEL"
            <> showDefault
            <> Options.Applicative.value INFO
        )

mainCommandParser :: Parser MainCommand
mainCommandParser =
  subparser
    ( command
        "to-redmine"
        ( info
            (ToRedmine <$> redmineParser <**> helper)
            (progDesc "Book times to redmine")
        )
        <> command
          "get-redmine"
          ( info
              (GetRedmineCommand <$> getRedmineCommandArgsParser <**> helper)
              (progDesc "Get times currently booked in redmine")
          )
    )

-- * Get booked times from Redmine

getRedmineMain :: GetRedmineCommandArgs -> IO ()
getRedmineMain args = do
  cfg <- getRedmineConfiguration
  let req = defaultGetTimeEntriesRequest {user_id = Just cfg.userId, from = args.fromDate, to = args.toDate}
  resp <- getTimeEntries cfg req
  forM_ (sortOn (\e -> e.spent_on) resp.time_entries) $ \entry -> do
    debugM (moduleLogger <> ".getRedmineMain") (show entry)
    TIO.putStrLn . prettyTimeEntry $ entry

prettyTimeEntry :: TimeEntry -> T.Text
prettyTimeEntry entry =
  T.intercalate
    "\t"
    [ T.pack (show entry.spent_on),
      T.pack . show $ entry.hours,
      entry.project.name
        <> " :: "
        <> entry.comments
    ]

getRedmineCommandArgsParser :: Parser GetRedmineCommandArgs
getRedmineCommandArgsParser =
  GetRedmineCommandArgs
    <$> optional (dateOption (long "from" <> help "The start day to fetch time entries"))
    <*> optional (dateOption (long "to" <> help "The start day until to fetch time entries"))

dateOption :: Mod OptionFields Day -> Parser Day
dateOption modifier = option auto (modifier <> metavar "DATE")

data GetRedmineCommandArgs = GetRedmineCommandArgs
  { fromDate :: !(Maybe Day),
    toDate   :: !(Maybe Day)
  }
  deriving (Eq, Show)

-- * Publish to Redmine

toRedmineMain :: ToRedmineArgs -> IO ()
toRedmineMain args = do
  cfg <- getRedmineConfiguration
  loglines <- readAgendaFile args.agendaFile
  mapM_ (debugM loggerName) $
    "Read log lines:" : map show loglines
  allEntries <- mapM (logLineToTimeEntryCreate cfg) loglines
  mapM_ (debugM loggerName) $
    "Mapped to the following time entries:" : map show allEntries

  let totalSpent :: Double = sum . map (\x -> x.hours) $ entries
      actuallySpent = sum . map loggedTime $ loglines
      entries = filter (\x -> x.hours /= 0) allEntries
  infoM loggerName $ "Create time entries with a total spent hours of: " <> show totalSpent
  infoM loggerName $ "Actually spent: " <> (show . timeToDaysAndTimeOfDay) actuallySpent
  when args.dryRun $ do
    die "Dry run mode! Exiting"
  forM_ entries $ \entry -> do
    infoM loggerName $ "Creating " <> show entry
    resp <- postTimeEntry cfg entry
    debugM loggerName $ "Result: " <> show resp
  where
    loggerName = moduleLogger <> ".toRedmineMain"

data ToRedmineArgs = ToRedmineArgs
  { dryRun     :: Bool,
    agendaFile :: String
  }
  deriving (Eq, Show)

redmineParser :: Parser ToRedmineArgs
redmineParser =
  ToRedmineArgs
    <$> switch (long "dry-run" <> short 'n' <> help "Do not create any time entry")
    <*> argument str (metavar "FILE" <> help "The agenda file to process")

getRedmineConfiguration :: IO RedmineConfig
getRedmineConfiguration = do
  baseRequest <- parseRequest =<< getFromEnv "REDMINE_URL" "the url of the Redmine instance"
  apiKey <- getFromEnv "REDMINE_API_KEY" "the API key of the Redmine instance"
  userId <- read <$> getFromEnv "REDMINE_USER_ID" "the user ID"
  projectMapFile <- getFromEnv "REDMINE_PROJECT_MAP" "the Redmine project map"
  projectMap <-
    eitherDecodeFileStrict projectMapFile >>= \case
      Left err -> die $ "Could not read project map file: " <> err
      Right m -> pure m
  pure RedmineConfig {..}

getFromEnv :: String -> String -> IO String
getFromEnv var help_ =
  lookupEnv var >>= \case
    Nothing -> die $ "Please set '" <> var <> "' to " <> help_
    Just value_ -> pure value_
