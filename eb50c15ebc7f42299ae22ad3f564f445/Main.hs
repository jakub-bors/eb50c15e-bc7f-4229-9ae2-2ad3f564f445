{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent.ParallelIO (stopGlobalPool)
import Control.Monad (msum)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Data.DateTime
import Data.Aeson (decode, encode, FromJSON, ToJSON)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy.UTF8 (toString)
import Data.Maybe (fromJust)
import Data.Pool (createPool, Pool, withResource)
import Data.Text (Text)
import Database.HDBC (commit, disconnect, fromSql, quickQuery', run, toSql)
import Database.HDBC.Sqlite3 (Connection, connectSqlite3)
import GHC.Generics
import Happstack.Server
import Happstack.Server.Compression (compressedResponseFilter)

type Environment = Pool Connection

data Event = Event {
    story :: Text,
    created :: DateTime,
    latitude :: Double,
    longitude :: Double
} deriving (Generic, Show)
instance FromJSON Event
instance ToJSON Event

getBody :: ServerPart ByteString
getBody = do
    req  <- askRq 
    body <- liftIO $ takeRequestBody req
    return . unBody $ fromJust body

listEvents :: Connection -> IO [Event]
listEvents conn = do
    rows <- quickQuery' conn "SELECT story, created, latitude, longitude FROM events ORDER BY created DESC" []
    return $ map rowToEvent rows
    where
        rowToEvent (story : created : latitude : longitude : []) = Event {
            story = fromSql story,
            created = fromSql created,
            latitude = fromSql latitude,
            longitude = fromSql longitude
        }

getEvents :: Connection -> ServerPart Response
getEvents conn = do
    result <- lift $ listEvents conn
    let response = toResponseBS "application/json; charset=utf-8" (encode result)
    ok response

createEvent :: Connection -> Event -> IO ()
createEvent conn event = do
    let Event { story, created, latitude, longitude } = event
    run conn "INSERT INTO events VALUES(?, ?, ?, ?)" [toSql story, toSql created, toSql latitude, toSql longitude]
    commit conn
    return ()

postEvent :: Connection -> ServerPart Response
postEvent conn = do
    body <- getBody
    let event = (fromJust . decode) body :: Event
    lift $ createEvent conn event
    resp 201 (result 201 "")

handlers :: Environment -> ServerPartT IO Response
handlers pool = msum
    [
        dir "events" $ do
            method GET
            nullDir
            withResource pool getEvents,
        dir "events" $ do
            method POST
            nullDir
            withResource pool postEvent 
    ]

main :: IO ()
main = do
    pool <- createPool (connectSqlite3 "database.db") disconnect 1 10 20
    simpleHTTP nullConf $ do
        _ <- compressedResponseFilter
        setHeaderM "Access-Control-Allow-Origin" "*"
        handlers pool
    stopGlobalPool
