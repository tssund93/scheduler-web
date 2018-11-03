{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
module Handler.Home where

import           Database.Persist.Sql
import           Import
import qualified Data.Graph                    as G
import           Priority
import           Data.Time
import           Data.Time.Calendar.WeekDate
import qualified Data.List                     as L
import           RepeatInterval
import           Yesod.Form.Bootstrap3
import qualified Data.Maybe                    as M
import qualified Data.Text                     as T

taskList :: [Entity Task] -> [Entity Task] -> Bool -> Maybe TimeOfDay -> Widget
taskList tasks postponedTasks todayPage estimatedToc = do
  (Entity userId user) <- requireAuth
  let mUserTz = userTimeZone user
  let formattedEstimatedToc = maybe
        ""
        (formatTime defaultTimeLocale "Estimated Completion Time: %l:%M %p")
        estimatedToc

  utcTime <- liftIO getCurrentTime
  let today = localDay $ fromMaybe (utcToLocalTime utc utcTime) $ utcToUserTime
        utcTime
        user
  allTasks <- handlerToWidget $ runDB $ getTasks userId []

  let userTz = fromMaybe utc $ userTimeZone user
  todaysTasks <- handlerToWidget $ todaysList $ Entity userId user

  tasksDeps <- handlerToWidget $ mapM
    (\t -> if M.isNothing (taskPostponeTime $ entityVal t)
      then return False
      else
        case taskPostponeTime (entityVal t) of
          Just ppt ->
            let tad = taskAndDependencies t in
            (<) 0
              <$> (   L.length
                  <$> (L.intersect <$> tad <*> do
                          tad' <- L.delete t <$> tad
                          let mins = minsDiff userTz ppt utcTime
                          daysList today mins (tad' `L.intersect` todaysTasks)
                      )
                  )
          Nothing -> return False
    )
    tasks
  let tasksHasDeps = zip tasks tasksDeps

  if todayPage
     then do
       let timedTasks = sortBy (\((Entity _ t1), _) ((Entity _ t2), _) ->
                         taskPostponeTime t1 `compare` taskPostponeTime t2)
                            $ filter (\((Entity _ t), _) ->
                                        isJust $ taskPostponeTime t)
                                     tasksHasDeps
       $(widgetFile "tasks-timed")
       $(widgetFile "tasks")
     else
       $(widgetFile "tasks")

getHomeR :: Handler Html
getHomeR = do
  setUltDestCurrent
  userId <- requireAuthId
  tasks' <- runDB $ getTasks userId []
  let (ns, js) =
        L.partition (\(Entity _ t) -> isNothing $ taskDueDate t) $ sortBy
          (\(Entity _ t1) (Entity _ t2) ->
            taskDueDate t1
              `compare` taskDueDate t2
              <>        taskPriority t2
              `compare` taskPriority t1
              <>        taskCreateTime t1
              `compare` taskCreateTime t2
          )
          tasks'
  let tasks = js ++ ns
  utcTime        <- liftIO getCurrentTime
  postponedTasks <- postponedTaskList utcTime tasks
  defaultLayout $ do
    setTitle "Manage Tasks"
    $(widgetFile "homepage")

sortTasks' :: [(Entity Task, [Entity Task])] -> [G.SCC (Entity Task, [Entity Task])]
sortTasks' tasksAndDeps = G.stronglyConnComp tasksDeps
 where
  tasksDeps = map
    (\(etask@(Entity _ task), deps) ->
      ( (etask, deps)
      , task
      , map (\(Entity _ dep) -> dep) deps
      )
    )
    tasksAndDeps

sortTasks :: [(Entity Task, [Entity Task])] -> [Entity Task]
sortTasks tasksAndDeps =
  map fst $ concatMap G.flattenSCC $ sortTasks' tasksAndDeps

highWeight :: Integer
highWeight = 99999
mediumWeight :: Integer
mediumWeight = lowWeight * 2
lowWeight :: Integer
lowWeight = 7
highOverdueMod :: Integer
highOverdueMod = lowOverdueMod * 3
mediumOverdueMod :: Integer
mediumOverdueMod = lowOverdueMod * 2
lowOverdueMod :: Integer
lowOverdueMod = 1
weight :: Day -> Task -> Integer
weight date task = case taskPriority task of
  High -> highWeight + case taskDueDate task of
    Just dd -> weightMod dd highOverdueMod
    Nothing -> -1
  Medium -> mediumWeight + case taskDueDate task of
    Just dd -> weightMod dd mediumOverdueMod
    Nothing -> -1
  Low -> lowWeight + case taskDueDate task of
    Just dd -> weightMod dd lowOverdueMod
    Nothing -> -1
  None -> 0
  where weightMod dd modifier = (date `diffDays` dd) * modifier

timeToComplete :: [Entity Task] -> Int
timeToComplete = foldr (\(Entity _ t) x -> x + taskDuration t) 0

data DueTime = DueTime
  { dueTime :: TimeOfDay
  } deriving Show

dueTimeForm :: Maybe TimeOfDay -> Form DueTime
dueTimeForm mdt =
  renderBootstrap3
      (BootstrapHorizontalForm (ColSm 0) (ColSm 4) (ColSm 0) (ColSm 4))
    $   DueTime
    <$> areq timeField (bfs ("When would you like to work until?" :: Text)) mdt
    <*  bootstrapSubmit ("Submit" :: BootstrapSubmit Text)

userTimeZone :: User -> Maybe TimeZone
userTimeZone user = fmap minutesToTimeZone $ userDueTimeOffset user

utcToUserTime :: UTCTime -> User -> Maybe LocalTime
utcToUserTime time user = do
  userTz <- userTimeZone user
  return $ utcToLocalTime userTz time

postponedTaskList :: UTCTime -> [Entity Task] -> Handler [Entity Task]
postponedTaskList currUtcTime tasks = tasksAndDependents
  $ filter postponed tasks
 where
  postponed (Entity _ task) = case taskPostponeTime task of
    Nothing     -> False
    Just ppTime -> currUtcTime < ppTime

tasksAndDependents :: [Entity Task] -> Handler [Entity Task]
tasksAndDependents tasks = tasksAndDependents' tasks []

tasksAndDependents' :: [Entity Task] -> [Entity Task] -> Handler [Entity Task]
tasksAndDependents' []    postponedTasks = return postponedTasks
tasksAndDependents' tasks postponedTasks = do
  tad               <- taskAndDependents (L.head tasks)
  newPostponedTasks <- tasksAndDependents' (L.tail tasks) tad
  return $ postponedTasks ++ newPostponedTasks

taskAndDependents :: Entity Task -> Handler [Entity Task]
taskAndDependents task = do
  dependents <- runDB $ selectList
    [ TaskDependencyDependsOnTaskId ==. entityKey task
    , TaskDependencyDeleted ==. False
    ]
    []
  let tdIds = map (\(Entity _ td) -> taskDependencyTaskId td) dependents
  dependentEntities <- runDB $ mapM
    (\tdId -> selectList
      [TaskId ==. tdId, TaskDeleted ==. False, TaskDone ==. False]
      []
    )
    tdIds
  more <- mapM taskAndDependents $ L.concat dependentEntities
  return $ task : L.concat more

taskAndDependencies :: Entity Task -> Handler [Entity Task]
taskAndDependencies task = do
  dependencies <- runDB $ selectList
    [TaskDependencyTaskId ==. entityKey task, TaskDependencyDeleted ==. False]
    []
  let tdIds =
        map (\(Entity _ td) -> taskDependencyDependsOnTaskId td) dependencies
  dependencyEntities <- runDB $ mapM
    (\tdId -> selectList
      [TaskId ==. tdId, TaskDeleted ==. False, TaskDone ==. False]
      []
    )
    tdIds
  more <- mapM taskAndDependencies $ L.concat dependencyEntities
  return $ L.nub $ task : L.concat more

getResetDueTimeR :: Handler Html
getResetDueTimeR = do
  (Entity userId _) <- requireAuth
  runDB $ update userId [UserDueTime =. Nothing]
  redirect TodayR

minsDiff :: TimeZone -> UTCTime -> UTCTime -> Int
minsDiff userTz big small
  | big < small = 0
  | otherwise =
    let big'            = timeToTimeOfDay $ utctDayTime big
        (dayAdj, big'') = utcToLocalTimeOfDay userTz big'
        bigTime                 = timeOfDayToTime big''

        small'                     = timeToTimeOfDay $ utctDayTime small
        (smallDayAdj, small'')               = utcToLocalTimeOfDay userTz small'
        smallTime                   = timeOfDayToTime small''

        timeOfDay = timeToTimeOfDay $ picosecondsToDiffTime
          (diffTimeToPicoseconds bigTime - diffTimeToPicoseconds smallTime)
    in
      (todHour timeOfDay * 60) + todMin timeOfDay

getTodayR :: Handler Html
getTodayR = do
  setUltDestCurrent
  (Entity userId user') <- requireAuth

  -- get current day in user's time zone
  utcTime       <- liftIO getCurrentTime
  let mCurrentUserDateTime = utcToUserTime utcTime user'

  -- get day of due time in user's time zone
  let mDueDateTime         = userDueTime user'
  let mDueUserDateTime     = mDueDateTime >>= (`utcToUserTime` user')

  -- if not the same day user set due time, reset it
  let shouldUpdateTime =
        (localDay <$> mDueUserDateTime) /= (localDay <$> mCurrentUserDateTime)
  runDB $ update
    userId
    [UserDueTime =. if shouldUpdateTime then Nothing else mDueDateTime]
  let user =
        if shouldUpdateTime then user' { userDueTime = Nothing } else user'

  allTasks  <- runDB $ getTasks userId []
  todaysTasksHandler "Today's Tasks" user (userDueTime user) allTasks Nothing

todaysList :: Entity User -> Handler [Entity Task]
todaysList euser = do
  let (Entity userId user) = euser
  utcTime       <- liftIO getCurrentTime
  allTasks  <- runDB $ getTasks userId []

  let mUserDueTime = userDueTime user
  case mUserDueTime of
    Just dt -> do
      let userTz = fromMaybe utc $ userTimeZone user

      let mins = minsDiff userTz dt utcTime

      let localTime = utcToLocalTime userTz utcTime
      let today = localDay localTime
      daysList today mins allTasks
    Nothing -> return []

todaysTasksHandler :: Text -> User -> Maybe UTCTime -> [Entity Task] -> Maybe TaskId -> Handler Html
todaysTasksHandler title user mDueTime tasks mtaskId = do
  utcTime       <- liftIO getCurrentTime

  case mDueTime of
    Just dt -> do
      let userTz = fromMaybe utc $ userTimeZone user

      let localDt =
            (utcToLocalTimeOfDay userTz . timeToTimeOfDay . utctDayTime) dt

      let mins = minsDiff userTz dt utcTime

      let localTime = utcToLocalTime userTz utcTime
      let today = localDay localTime
      let localTod = localTimeOfDay localTime
      reducedTasks <- daysList today mins tasks

      let estimatedToc = if null reducedTasks
            then Nothing
            else Just $ estimateTimeOfCompletion reducedTasks localTod

      postponedTasks <- postponedTaskList utcTime reducedTasks
      if isJust mtaskId && null reducedTasks
        then redirect TodayR
        else
          defaultLayout $ do
            setTitle $ toHtml title
            [whamlet|$if isJust mtaskId
                        <h3>#{title}|]
            $(widgetFile "work-message")
            taskList reducedTasks postponedTasks True estimatedToc
    Nothing -> do
      (widget, enctype) <- generateFormPost $ dueTimeForm Nothing
      defaultLayout $ do
        if null tasks
           then do
             setTitle "Today's Tasks"
             taskList [] [] True Nothing
           else do
             setTitle "Set Time"
             setTimeWidget widget enctype

estimateTimeOfCompletion :: [Entity Task] -> TimeOfDay -> TimeOfDay
estimateTimeOfCompletion tasks tod = TimeOfDay hours mins (todSec tod)
 where
  taskMins = timeToComplete tasks
  mins     = (todMin tod + taskMins) `mod` 60
  hours    = (todHour tod + ((todMin tod + taskMins) `div` 60)) `mod` 24

formatPostponeTime :: TimeZone -> Entity Task -> String
formatPostponeTime userTz (Entity _ task) = case taskPostponeTime task of
  Just time -> formatTime defaultTimeLocale "%l:%M %p" $ userTime time
  Nothing   -> ""
  where userTime = utcToLocalTime userTz

setTimeWidget :: Widget -> Enctype -> Widget
setTimeWidget widget enctype =
  $(widgetFile "set-time")

postTodayR :: Handler Html
postTodayR = do
  (Entity _ user)     <- requireAuth
  ((res, _widget), _enctype) <- runFormPost $ dueTimeForm Nothing
  case res of
    FormSuccess dt -> do
      userId <- requireAuthId

      let tzOffsetMins = fromMaybe 0 $ userDueTimeOffset user
      let userTz       = minutesToTimeZone tzOffsetMins
      utcTime <- liftIO getCurrentTime
      let userTime             = utcToLocalTime userTz utcTime

      let (dayAdj, utcDueTime) = localToUTCTimeOfDay userTz $ dueTime dt

      runDB $ update
        userId
        [ UserDueTime
            =. Just
                 (UTCTime (addDays dayAdj (localDay userTime))
                          (timeOfDayToTime utcDueTime)
                 )
        ]
      redirect TodayR
    _ -> do
      setMessage "Error updating time"
      redirect TodayR

dueByDay :: Day -> [Entity Task] -> [Entity Task]
dueByDay day = filter (dueByOrBeforeDay day)
 where
  dueByOrBeforeDay d (Entity _ t) = case taskDueDate t of
    Just dd -> case taskPostponeDay t of
      Just ppd -> dd <= d && ppd <= d
      Nothing  -> dd <= d
    Nothing -> True

utcToday :: IO Day
utcToday = utctDay <$> getCurrentTime

reduceLoad :: Day -> Int -> [Entity Task] -> [Entity Task]
reduceLoad date mins tasks
  | timeToComplete tasks > mins && not (allHighPriority tasks)
  = reduceLoad date mins
    $ L.tail
    $ L.sortBy
        (\et1@(Entity _ t1) et2@(Entity _ t2) ->
          lowestWeight et1 et2 <> (taskDuration t2 `compare` taskDuration t1)
        )
    $ L.sortBy
        (\(Entity _ t1) (Entity _ t2) ->
          taskCreateTime t2 `compare` taskCreateTime t1
        )
        tasks
  | otherwise
  = tasks
 where
  lowestWeight (Entity _ t1) (Entity _ t2) =
    weight date t1 `compare` weight date t2
  allHighPriority = foldr (\(Entity _ t) b -> b && taskPriority t == High) True

fillInGaps :: Int -> [Entity Task] -> [Entity Task] -> [Entity Task]
fillInGaps mins allTasks reducedTasks
  | null allTasks
  = reducedTasks
  | allTasks == reducedTasks
  = reducedTasks
  | timeToComplete reducedTasks
    + L.minimum (map (\(Entity _ t) -> taskDuration t) potTasks)
    > mins
  = reducedTasks
  | otherwise
  = let sortedPot = sortBy highestPriorityThenShortestLength potTasks
    in  fillInGaps
          mins
          (L.tail sortedPot)
          (if timeToComplete reducedTasks
               + taskDuration (getTaskFromEntity $ L.head sortedPot)
               < mins
            then L.head sortedPot : reducedTasks
            else reducedTasks
          )
 where
  potTasks =
    filter (\(Entity _ t) -> not $ taskDone t) allTasks L.\\ reducedTasks
  highestPriorityThenShortestLength (Entity _ a) (Entity _ b) =
    taskPriority b
      `compare` taskPriority a
      <>        taskDuration a
      `compare` taskDuration b
  getTaskFromEntity (Entity _ t) = t

daysList
  :: Day -> Int -> [Entity Task] -> Handler [Entity Task]
daysList day mins tasks = do
  let todaysTasks = ( fillInGaps mins (dueByDay day tasks)
                    . reduceLoad day mins
                    . dueByDay day
                    )
                    tasks
  tasksAndDeps <- mapM taskAndDeps todaysTasks
  return $ sortTasks tasksAndDeps
  where taskAndDeps task = do
              dependencies <- runDB $ selectList
                [TaskDependencyTaskId ==. entityKey task, TaskDependencyDeleted ==. False]
                []
              let tdIds =
                    map (\(Entity _ td) -> taskDependencyDependsOnTaskId td) dependencies
              dependencyEntities <- runDB $ mapM
                (\tdId -> selectList
                  [TaskId ==. tdId, TaskDeleted ==. False, TaskDone ==. False]
                  []
                )
                tdIds
              return (task, L.concat dependencyEntities)

postMarkDoneR :: TaskId -> Handler Html
postMarkDoneR taskId = do
  setUltDestReferer
  task    <- runDB $ get taskId
  utcTime <- liftIO getCurrentTime
  runDB $ update taskId [TaskDone =. True, TaskDoneTime =. Just utcTime]
  (Entity _ user) <- requireAuth
  let userTzOffset = fromMaybe 0 $ userDueTimeOffset user
  let cdate =
        localDay $ utcToLocalTime (minutesToTimeZone userTzOffset) utcTime
  _ <- runDB $ case task of
    Just t -> case incrementDueDate cdate t of
      Just t2 -> do
        newTaskId <- insert
          $ t2 { taskPostponeDay = Nothing,
                 taskPostponeTime = if taskPostponeTimeRepeat t
                                    then newPostponeTime t2
                                    else Nothing
               }
        deps <- selectList [TaskDependencyTaskId ==. taskId] []
        depd <- selectList [TaskDependencyDependsOnTaskId ==. taskId] []
        _ <- mapM
          (\(Entity _ dep) -> insert $ TaskDependency
            newTaskId
            (taskDependencyDependsOnTaskId dep)
            False
          )
          deps
        mapM
          (\(Entity _ dep) ->
            insert $ TaskDependency (taskDependencyTaskId dep) newTaskId False
          )
          depd
      Nothing -> redirectUltDest HomeR
    Nothing -> redirectUltDest HomeR
  redirectUltDest HomeR
  where newPostponeTime newTask = do
          case taskDueDate newTask of
            Nothing -> Nothing
            Just dd -> do
              oldPpt <- taskPostponeTime newTask
              Just $ UTCTime dd (utctDayTime oldPpt)

incrementDueDate :: Day -> Task -> Maybe Task
incrementDueDate cdate task = case taskDueDate task of
  Just dd -> case taskRepeat task of
    Just (OnWeekdays wkdays CompletionDate) -> do
      let (_, _, wkdayNum) = toWeekDate cdate
      let nextWkday        = next $ weekdayFromInt wkdayNum
      if nextWkday `elem` wkdays
        then Just task { taskDueDate = Just (addDays 1 cdate) }
        else incrementDueDate (addDays 1 cdate) task
    Just (OnWeekdays wkdays DueDate) -> do
      let (_, _, wkdayNum) = toWeekDate dd
      let potWkdays = map weekdayFromInt [wkdayNum + 1 .. wkdayNum + 7]
      let matches          = map (`elem` wkdays) potWkdays
      let offset           = fmap (+ 1) (True `L.elemIndex` matches)
      case offset of
        Nothing -> Nothing
        Just o  -> Just task { taskDueDate = Just (addDays (toInteger o) dd) }
    Just (Days ivl CompletionDate) ->
      Just task { taskDueDate = Just (addDays ivl cdate) }
    Just (Weeks ivl CompletionDate) ->
      Just task { taskDueDate = Just (addDays (ivl * 7) cdate) }
    Just (Months ivl CompletionDate) ->
      Just task { taskDueDate = Just (addGregorianMonthsClip ivl cdate) }
    Just (Years ivl CompletionDate) ->
      Just task { taskDueDate = Just (addGregorianYearsClip ivl cdate) }
    Just (Days ivl DueDate) ->
      Just task { taskDueDate = Just (addDays ivl dd) }
    Just (Weeks ivl DueDate) ->
      Just task { taskDueDate = Just (addDays (ivl * 7) dd) }
    Just (Months ivl DueDate) ->
      Just task { taskDueDate = Just (addGregorianMonthsClip ivl dd) }
    Just (Years ivl DueDate) ->
      Just task { taskDueDate = Just (addGregorianYearsClip ivl dd) }
    Nothing -> Nothing
  Nothing -> Nothing

getTodayDepsR :: TaskId -> Handler Html
getTodayDepsR taskId = do
  setUltDestCurrent

  (Entity userId user) <- requireAuth
  mTask                <- runDB $ getEntity taskId

  case mTask of
    Just task -> do
      todaysTasks <- todaysList $ Entity userId user

      tasks' <- taskAndDependencies task
      let tasks'' = L.delete task tasks'

      todaysTasksHandler ("\""
                          ++ taskName (entityVal task)
                          ++ "\" Dependencies")
              user
              (taskPostponeTime $ entityVal task)
              (tasks'' `L.intersect` todaysTasks)
              (Just $ entityKey task)
    Nothing -> redirect TodayR

getTasks userId =
  selectList [TaskUserId ==. userId, TaskDone ==. False, TaskDeleted ==. False]
