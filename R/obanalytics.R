# Copyright (C) 2019 Petr Fedorov <petr.fedorov@phystech.edu>

# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation,  version 2 of the License

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.


#' @importFrom lubridate with_tz ymd_hms seconds ceiling_date floor_date now minutes duration round_date
#' @importFrom dplyr lead if_else filter select full_join rename mutate
#' @importFrom plyr . empty
#' @importFrom zoo na.locf
#' @importFrom magrittr  %>%
#' @importFrom purrr pmap_dfr
#' @importFrom tibble tibble
#' @import data.table
#' @useDynLib obadiah


.dummy <- function() {}

#' Securely connects to the OBADiah database and initializes an internal cache for the data
#'
#' Establishes a secure TCP/IP connection to the OBADiah database and returns a connection object.
#' The object is used to communicate with the database and to keep refereneces cached data
#'
#' @param host name or IP address of the PostgreSQL server running the OBADiah database
#' @param port port
#' @param sslcert path to the client's SSL certificate file, signed by OBADiah database owner
#' @param sslkey path to the clients' SSL private key
#' @param sslrootcert path to the clients' SSL root certificate
#' @param user user
#' @param dbname name of PostgreSQL database
#' @param use.cache if TRUE, the downloaded data will be cached on the client-side
#' @return the connection object
#'
#' @export
connect <- function(host, port, sslcert=NULL, sslkey=NULL, sslrootcert =system.file('extdata/root.crt', package=packageName()), user="obademo",  dbname="ob-analytics-prod", use.cache = TRUE) {

  con <-new.env()
  con$use.cache <- use.cache

  con$con <- (function() {
    dbObj <- NULL
    function() {
      while(is.null(dbObj) || tryCatch(DBI::dbGetQuery(dbObj, "select false as result")$result, error = function(e) TRUE )) {
        dbObj <<- DBI::dbConnect(RPostgres::Postgres(),
                       user=user,
                       dbname=dbname,
                       host=host,
                       port=port,
                       sslmode="allow",
                       sslrootcert=system.file('extdata/root.crt', package=packageName()),
                       sslcert=sslcert,
                       sslkey=sslkey,
                       bigint="numeric")
      }
      dbObj
    }
  })()
  class(con) <- c("connection", class(con))
  con
}

#' @export
#'
disconnect <- function(con) {
  DBI::dbDisconnect(con$con())
}

#' @export
getQuery <- function(x, ...) {
  UseMethod("getQuery")
}

getQuery.default <- function(con, query) {
  DBI::dbGetQuery(con, query)
}



#' Calculates and downloads depth changes from the OBADiah database
#'
#' A depth change is the new bid or ask volume  offered at some price in an exchange order book at some moment in time.
#' The change is caused by placement or cancellation of an order which happened on the exchange either at the time of the reported depth change
#' or between the current and pervious reported sample times if the depth changes are calculated using fixed frequency.
#'
#' The depth changes are calculated as if before \code{start.time} the order book was empty, which effectively means that  the initial state of the order book at the start.time is conveyed.
#' The function ignores interruptions in the data and calculates depth changes over the interruptions. This may lead to the presence of long gaps between consecutive changes.
#' Not every order placement and/or cancellation produces a depth change. For example, if an order placement and cancellation are reported as happened at the same time, the depth change will
#' not be generated.
#'
#' @param con a connection object as returned by \code{\link{connect}}
#' @param start.time POSIXct or character vector understood by \code{\link{ymd_hms}}
#' @param end.time POSIXct or character vector understood by \code{\link{ymd_hms}}
#' @param exchange a character vector with the name of the exchange
#' @param pair a character vector with the name of the pair
#' @param frequency if NULL, the actual depth changes are returned. Otherwise an integer number of seconds between depth samples.
#' @param tz a character vector with a time zone name understood by \code{\link{with_tz}} for the \code{timestamp} column in the output
#' @returns A data.table with one row per the depth change reported. The following information is provided for each depth change
#' \describe{
#'  \item{timestmap POSIXct}{timestamp of the depth change}
#'  \item{price numeric}{the price level for which the depth change is reported}
#'  \item{volume numeric}{The new amount available at the price level. Will be zero, when the last order with the given price will leave the order book.}
#'  \item{side character}{the side of the order book where the price level currently resides.  Either 'bid' or 'ask'.}
#'  \item{pair character}{a character vector with the pair name}
#'  \item{exchange character}{a character vector with the pair name}
#' }
#'
#' @export
depth <- function(con, start.time, end.time, exchange, pair, frequency=NULL,  tz='UTC') {

  if(con$use.cache) cache = con else cache=NULL
  conn=con$con()
  cache.bound = now(tz='UTC') - minutes(15)

  if(is.character(start.time)) start.time <- ymd_hms(start.time)
  if(is.character(end.time)) end.time <- ymd_hms(end.time)

  stopifnot(inherits(start.time, 'POSIXt') & inherits(end.time, 'POSIXt'))
  stopifnot(is.null(frequency) || is.numeric(frequency))
  stopifnot(is.null(frequency) || frequency < 3600 || (frequency > 60 && frequency %% 60 == 0) || frequency < 60 && frequency > 0)

  if(is.null(frequency))
    flog.debug(paste0("depth(conn,", shQuote(format(start.time, usetz=T)), "," , shQuote(format(end.time, usetz=T)),",", shQuote(exchange), ", ", shQuote(pair),")" ), name=packageName())
  else
    flog.debug(paste0("depth(conn,", shQuote(format(start.time, usetz=T)), "," , shQuote(format(end.time, usetz=T)),",", shQuote(exchange), ", ", shQuote(pair),",", frequency, ")" ), name=packageName())

  tzone <- tz

  # Convert to UTC, so internally only UTC is used
  start.time <- with_tz(start.time, tz='UTC')
  end.time <- with_tz(end.time, tz='UTC')
  starting_depth <- .starting_depth(conn, start.time, exchange, pair, frequency)
  if(is.null(cache) || start.time > cache.bound)
    depth_changes <- .depth_changes(conn, start.time, end.time, exchange, pair, frequency)
  else {
    if(is.null(frequency)) {
      cache_key <- "depth"
      right <- FALSE
    }
    else {
      cache_key <- paste0("depth",frequency)
      right <- TRUE
      if(frequency < 60)
        end.time <- ceiling_date(end.time, paste0(frequency, " seconds"))
      else
        end.time <- ceiling_date(end.time, paste0(frequency %/% 60, " minutes"))
    }
    loader <- function(conn, start.time, end.time, exchange, pair) {
      .depth_changes(conn, start.time, end.time, exchange, pair, frequency)
      }
    if(end.time <= cache.bound )
      depth_changes <- .load_cached(conn, start.time, end.time, exchange, pair,loader, .leaf_cache(cache, exchange, pair, cache_key), right=right)
    else
      depth_changes <- rbind(.load_cached(conn, start.time, cache.bound, exchange, pair, loader, .leaf_cache(cache, exchange, pair, cache_key), right=right ),
                             loader(conn, cache.bound, end.time, exchange, pair)
                            )
  }
  depth <- rbind(starting_depth, depth_changes)

  depth [ ,c("timestamp", "pair", "exchange") := .(with_tz(timestamp, tzone), pair, exchange)]
  depth
}


.load_cached <- function(conn, start.time, end.time, exchange, pair, loader, cache, right=FALSE) {

  .update_cache(conn, floor_date(start.time), ceiling_date(end.time), exchange, pair, loader, cache)
  .load_from_cache(start.time, end.time, cache, right=right)
}


.depth_changes <- function(conn, start.time, end.time, exchange, pair, frequency = NULL)   {
  if(is.null(frequency))
    query <- paste0(" SELECT timestamp, price, volume, side  FROM get.depth(",
                    shQuote(format(start.time, usetz=T)), ",",
                    shQuote(format(end.time, usetz=T)), ",",
                    "get.pair_id(",shQuote(pair),"), " ,
                    "get.exchange_id(", shQuote(exchange), "), ",
                    "p_starting_depth := false, p_depth_changes := true) ORDER BY 1, 2 DESC")
  else
    query <- paste0(" SELECT timestamp,price, volume, side  FROM get.depth(",
                    shQuote(format(start.time, usetz=T)), ",",
                    shQuote(format(end.time, usetz=T)), ",",
                    "get.pair_id(",shQuote(pair),"), " ,
                    "get.exchange_id(", shQuote(exchange), "), ",
                    "p_frequency :=", shQuote(paste0(frequency, " seconds ")), ",",
                    "p_starting_depth := false, p_depth_changes := true) ORDER BY 1, 2 DESC")
  flog.debug(query, name=packageName())
  depth <- getQuery(conn, query)
  setDT(depth)
  depth[, c("timestamp") := .(as.POSIXct(timestamp/1000000.0, origin="2000-01-01")) ]
  depth
}


.starting_depth <- function(conn, start.time, exchange, pair, frequency)   {
  if(is.null(frequency))
    query <- paste0("SELECT timestamp, price, volume, side FROM get.depth(",
                    shQuote(format(start.time,usetz=T)), ", NULL, ",
                    "get.pair_id(",shQuote(pair),"), " ,
                    "get.exchange_id(", shQuote(exchange), "), ",
                    "p_starting_depth := true, p_depth_changes := false) ORDER BY 1, 2 DESC")
  else
    query <- paste0("SELECT timestamp, price, volume, side FROM get.depth(",
                    shQuote(format(start.time,usetz=T)), ", NULL, ",
                    "get.pair_id(",shQuote(pair),"), " ,
                    "get.exchange_id(", shQuote(exchange), "), ",
                    "p_frequency := ", shQuote(paste0(frequency, " seconds ")), ", ",
                    "p_starting_depth := true, p_depth_changes := false) ORDER BY 1,2 DESC")
  flog.debug(query, name=packageName())
  depth <- getQuery(conn, query)
  setDT(depth)
  depth[, c("timestamp") := .(as.POSIXct(timestamp/1000000.0, origin="2000-01-01")) ]
  depth
}




#' @export
spread <- function(x, ...) {
  UseMethod("spread")
}


#' @export
spread.data.table <- function(depth, skip.crossed=TRUE, complete.cases=TRUE, tz='UTC') {
  spread <- with(depth, spread_from_depth(timestamp, price, volume, side))
  data.table::setDT(spread)

  if(complete.cases)
    spread <- spread[complete.cases(spread), ]

  if(skip.crossed)
    spread <- spread[best.bid.price <= best.ask.price, ]

  spread[, c("timestamp", "pair", "exchange") := .(with_tz(timestamp, tz), depth$pair[1], depth$exchange[1]) ]
  spread
}

#' @export
spread.connection <- function(con, start.time, end.time, exchange, pair, frequency=NULL, skip.crossed=TRUE, complete.cases=TRUE, tz='UTC') {
  # TODO Implement loading of starting spread, similar to loading of starting depth (i.e. not distorting cache) ###
  if(con$use.cache) cache = con else cache=NULL
  conn=con$con()
  cache.bound = now(tz='UTC') - minutes(15)

  if(is.character(start.time)) start.time <- ymd_hms(start.time)
  if(is.character(end.time)) end.time <- ymd_hms(end.time)

  stopifnot(inherits(start.time, 'POSIXt') & inherits(end.time, 'POSIXt'))
  stopifnot(is.null(frequency) || is.numeric(frequency))
  stopifnot(is.null(frequency) || frequency < 3600 || (frequency > 60 && frequency %% 60 == 0) || frequency < 60 && frequency > 0)

  flog.debug(paste0("spread(con,", format(start.time, usetz=T), "," , format(end.time, usetz=T),",", shQuote(exchange), ", ", shQuote(pair),
                    ", frequency := ", frequency, ", skip.crossed := ", skip.crossed, ", complete.cases :=", complete.cases ,")" ), name=packageName())

  tzone <- tz

  # Convert to UTC, so internally only UTC is used
  start.time <- with_tz(start.time, tz='UTC')
  end.time <- with_tz(end.time, tz='UTC')


  if (is.null(frequency)) {
    cache_key <- "spread"
    right <- FALSE
  }
  else {

    if(frequency < 60) {
      #start.time <- floor_date(start.time,  paste0(frequency, " seconds"))
      end.time <- ceiling_date(end.time, paste0(frequency, " seconds"))
    }
    else {
      #start.time <- floor_date(start.time, paste0(frequency %/% 60, " minutes"))
      end.time <- ceiling_date(end.time, paste0(frequency %/% 60, " minutes"))
    }

    cache_key <- paste0("spread_",frequency)
    right <- TRUE
  }

  loader <- function(conn, start.time, end.time, exchange, pair) {
    .spread(conn, start.time, end.time, exchange, pair, frequency)
  }

  spread <- pmap_dfr(tibble(pair, exchange), function(pair, exchange) {

    starting_spread <- .starting_spread(conn, start.time, exchange, pair, frequency)

    if(is.null(cache) || start.time > cache.bound) {
      spread <- loader(conn, start.time, end.time, exchange, pair)
    }
    else {
      if(end.time <= cache.bound )
        spread <- .load_cached(conn, start.time, end.time, exchange, pair, loader, .leaf_cache(cache, exchange, pair, cache_key), right)
      else
        spread <- rbind(.load_cached(conn, start.time, cache.bound, exchange, pair, loader, .leaf_cache(cache, exchange, pair, cache_key), right),
                        loader(conn, cache.bound, end.time, exchange, pair)
        )
    }
    spread <- rbind(starting_spread, spread)

    if(!empty(spread)) {
      spread <- spread %>%
        mutate(timestamp=with_tz(spread$timestamp, tz),
               pair=pair,
               exchange=exchange)

    }
    if(complete.cases)
      spread <- spread[complete.cases(spread), ]
    if(skip.crossed)
      spread <- spread %>% filter(best.bid.price <= best.ask.price)
    spread

  })
  data.table::setDT(spread)
  spread
}

.starting_spread <- function(conn, start.time, exchange, pair, frequency) {

  if(is.null(frequency))

    query <- paste0(" SELECT timestamp, \"best.bid.price\", \"best.bid.volume\",",
                    "\"best.ask.price\", \"best.ask.volume\" FROM get.spread(",
                    shQuote(format(start.time, usetz=T)), ",",
                    "get.pair_id(",shQuote(pair),"), " ,
                    "get.exchange_id(", shQuote(exchange), ") ",
                    ")")
  else
    query <- paste0(" SELECT timestamp, \"best.bid.price\", \"best.bid.volume\",",
                    "\"best.ask.price\", \"best.ask.volume\" FROM get.spread(",
                    shQuote(format(start.time, usetz=T)), ",",
                    "get.pair_id(",shQuote(pair),"), " ,
                    "get.exchange_id(", shQuote(exchange), "), ",
                    "p_frequency :=", shQuote(paste0(frequency, " seconds ")),
                    ")")

  flog.debug(query, name=packageName())
  spread <- DBI::dbGetQuery(conn, query)
  setDT(spread)
  if(nrow(spread) > 0) {
    spread[, c("timestamp") := .(as.POSIXct(timestamp/1000000.0, origin="2000-01-01")) ]
  }
  spread
}




.spread <- function(conn, start.time, end.time, exchange, pair, frequency) {

  if(is.null(frequency))

    query <- paste0(" SELECT timestamp, \"best.bid.price\", \"best.bid.volume\",",
                    "\"best.ask.price\", \"best.ask.volume\" FROM get.spread(",
                    shQuote(format(start.time, usetz=T)), ",",
                    shQuote(format(end.time, usetz=T)), ",",
                    "get.pair_id(",shQuote(pair),"), " ,
                    "get.exchange_id(", shQuote(exchange), ") ",
                    ") order by 1")
  else
    query <- paste0(" SELECT timestamp, \"best.bid.price\", \"best.bid.volume\",",
                    "\"best.ask.price\", \"best.ask.volume\" FROM get.spread(",
                    shQuote(format(start.time, usetz=T)), ",",
                    shQuote(format(end.time, usetz=T)), ",",
                    "get.pair_id(",shQuote(pair),"), " ,
                    "get.exchange_id(", shQuote(exchange), "), ",
                    "p_frequency :=", shQuote(paste0(frequency, " seconds ")),
                    ") order by 1")

  flog.debug(query, name=packageName())
  spread <- DBI::dbGetQuery(conn, query)
  setDT(spread)
  if(nrow(spread) > 0) {
    spread[, c("timestamp") := .(as.POSIXct(timestamp/1000000.0, origin="2000-01-01")) ]
  }
  spread
}




#' @export
events <- function(con, start.time, end.time, exchange, pair, tz='UTC') {
  if(con$use.cache) cache = con else cache=NULL
  conn=con$con()
  cache.bound = now(tz='UTC') - minutes(15)

  if(is.character(start.time)) start.time <- ymd_hms(start.time)
  if(is.character(end.time)) end.time <- ymd_hms(end.time)

  stopifnot(inherits(start.time, 'POSIXt') & inherits(end.time, 'POSIXt'))

  flog.debug(paste0("events(con,", format(start.time, usetz=T), "," , format(end.time, usetz=T),",", exchange, ", ", pair,")" ), name=packageName())

  tzone <- tz

  # Convert to UTC, so internally only UTC is used
  start.time <- with_tz(start.time, tz='UTC')
  end.time <- with_tz(end.time, tz='UTC')

  if(is.null(cache) || start.time > cache.bound)
    events <- .events(conn, start.time, end.time, exchange, pair)
  else
    if(end.time <= cache.bound )
      events <- .load_cached(conn, start.time, end.time, exchange, pair, .events, .leaf_cache(cache, exchange, pair, "events"))
    else
      events <- rbind(.load_cached(conn, start.time, cache.bound, exchange, pair, .events, .leaf_cache(cache, exchange, pair, "events") ),
                             .events(conn, cache.bound, end.time, exchange, pair)
      )

  if(!empty(events)) {
    # Assign timezone of start.time, if any, to timestamp column
    events$timestamp <- with_tz(events$timestamp, tzone)
  }
  events  %>% arrange(event.id)
}



.events <- function(conn, start.time, end.time, exchange, pair) {

  start.time <- format(start.time, usetz=T)
  end.time <- format(end.time, usetz=T)


  query <- paste0(" SELECT 	\"event.id\",
                  \"id\"::numeric,
                  timestamp,
                  \"exchange.timestamp\",
                  price,
                  volume,
                  action,
                  direction,
                  fill,
                  \"matching.event\",
                  \"type\",
                  \"aggressiveness.bps\"
                  FROM get.events(",
                  shQuote(format(start.time, usetz=T)), ",",
                  shQuote(format(end.time, usetz=T)), ",",
                  "get.pair_id(",shQuote(pair),"), " ,
                  "get.exchange_id(", shQuote(exchange), ")",
                  ")")
  flog.debug(query, name=packageName())
  events <- DBI::dbGetQuery(conn, query)
  setDT(events)
  events[, c("timestamp",
             "exchange.timestamp",
             "action", "direction",
             "type") := .(as.POSIXct(timestamp/1000000.0, origin="2000-01-01"),
                          as.POSIXct(exchange.timestamp/1000000.0, origin="2000-01-01"),
                          factor(action, c("created", "changed", "deleted")),
                          factor(direction, c("bid", "ask")),
                          factor(type, c("market", "market-limit", "pacman",
                                         "flashed-limit","resting-limit", "unknown"))
                          ) ]
  events
}

#' @export
trades <- function(con, start.time, end.time, exchange, pair, tz='UTC') {

  if(con$use.cache) cache = con else cache=NULL
  conn=con$con()
  cache.bound = now(tz='UTC') - minutes(15)

  if(is.character(start.time)) start.time <- ymd_hms(start.time)
  if(is.character(end.time)) end.time <- ymd_hms(end.time)

  stopifnot(inherits(start.time, 'POSIXt') & inherits(end.time, 'POSIXt'))

  flog.debug(paste0("trades(con,", format(start.time, usetz=T), "," , format(end.time, usetz=T),",", exchange, ", ", pair,")" ), name=packageName())

  tzone <- tz

  # Convert to UTC, so internally only UTC is used
  start.time <- with_tz(start.time, tz='UTC')
  end.time <- with_tz(end.time, tz='UTC')

  if(is.null(cache) || start.time > cache.bound)
    trades <- .trades(conn, start.time, end.time, exchange, pair)
  else
    if(end.time <= cache.bound )
      trades <- .load_cached(conn, start.time, end.time, exchange, pair, .trades, .leaf_cache(cache, exchange, pair, "trades"))
  else
    trades <- rbind(.load_cached(conn, start.time, cache.bound, exchange, pair, .trades, .leaf_cache(cache, exchange, pair, "trades") ),
                    .trades(conn, cache.bound, end.time, exchange, pair)
    )

  if(!empty(trades)) {
    # Assign timezone of start.time, if any, to timestamp column
    trades$timestamp <- with_tz(trades$timestamp, tzone)
  }
  trades  %>% arrange(timestamp)
}


.trades <- function(conn, start.time, end.time, exchange, pair) {

  query <- paste0(" SELECT 	timestamp, price, volume, direction, \"maker.event.id\", \"taker.event.id\",",
                  " maker::numeric, taker::numeric, \"exchange.trade.id\" FROM get.trades(",
                  shQuote(format(start.time, usetz=T)), ",",
                  shQuote(format(end.time, usetz=T)), ",",
                  "get.pair_id(",shQuote(pair),"), " ,
                  "get.exchange_id(", shQuote(exchange), ")",
                  ") ORDER BY timestamp")
  flog.debug(query, name=packageName())
  trades <- DBI::dbGetQuery(conn, query)

  setDT(trades)
  trades[, c("timestamp") := .(as.POSIXct(timestamp/1000000.0, origin="2000-01-01")) ]
  trades
}


#' @export
depth_summary <- function(conn, start.time, end.time, exchange, pair, frequency=NULL, tz='UTC') {

  if(con$use.cache) cache = con else cache=NULL
  conn=con$con()
  cache.bound = now(tz='UTC') - minutes(15)

  if(is.character(start.time)) start.time <- ymd_hms(start.time)
  if(is.character(end.time)) end.time <- ymd_hms(end.time)

  stopifnot(inherits(start.time, 'POSIXt') & inherits(end.time, 'POSIXt'))

  flog.debug(paste0("depth_summary(con,", format(start.time, usetz=T), "," , format(end.time, usetz=T),",", shQuote(exchange), ", ", shQuote(pair),")" ), name=packageName())

  tzone <- tz

  # Convert to UTC, so internally only UTC is used
  start.time <- with_tz(start.time, tz='UTC')
  end.time <- with_tz(end.time, tz='UTC')


  if(is.null(cache) || start.time > cache.bound)
    ds <- .depth_summary(conn, start.time, end.time, exchange, pair, frequency)
  else {
    if(is.null(frequency)) {
      cache_key <- "depth_summary"
      right <- FALSE
    }
    else {
      cache_key <- paste0("depth_summary",frequency)
      right <- TRUE
      if(frequency < 60)
        end.time <- ceiling_date(end.time, paste0(frequency, " seconds"))
      else
        end.time <- ceiling_date(end.time, paste0(frequency %/% 60, " minutes"))
    }
    loader <- function(conn, start.time, end.time, exchange, pair) {
      .depth_summary(conn, start.time, end.time, exchange, pair, frequency)
    }

    if(end.time <= cache.bound )
      ds <- .load_cached(conn, start.time, end.time, exchange, pair, loader, .leaf_cache(cache, exchange, pair, cache_key), right)
    else
      ds <- rbind(.load_cached(conn, start.time, cache.bound, exchange, pair, loader, .leaf_cache(cache, exchange, pair, cache_key), right ),
                    loader(conn, cache.bound, end.time, exchange, pair)
    )
  }
  ds <- ds %>%
    filter(bps_level == 0) %>%
    select(-volume) %>%
    dcast(list(.(timestamp), .(paste0(side,'.price',bps_level, "bps"))), value.var="price")   %>%
    full_join(ds %>%
                select(-price) %>%
                dcast(list(.(timestamp), .(paste0(side,'.vol',bps_level, "bps"))), value.var="volume")
              , by="timestamp" ) %>%  rename(best.ask.price = ask.price0bps,
                                             best.bid.price = bid.price0bps,
                                             best.ask.vol = ask.vol0bps,
                                             best.bid.vol = bid.vol0bps)

  bid.names <- paste0("bid.vol", seq(from = 25, to = 500, by = 25),
                      "bps")
  ask.names <- paste0("ask.vol", seq(from = 25, to = 500, by = 25),
                      "bps")
  ds[setdiff(bid.names, colnames(ds))] <- 0
  ds[setdiff(ask.names, colnames(ds))] <- 0
  ds[is.na(ds)] <- 0

  if(!empty(ds)) {
    # Assign timezone of start.time, if any, to timestamp column
    ds$timestamp <- with_tz(ds$timestamp, tzone)
  }
  ds
}


.depth_summary <- function(conn, start.time, end.time, exchange, pair, frequency) {
  if(is.null(frequency))
    query <- paste0(" with depth_summary as ( select timestamp, price, volume, side, bps_level, rank() over (partition by get._in_milliseconds(timestamp) order by timestamp desc) as r ",
                    " from get.depth_summary(",
                    shQuote(format(start.time, usetz=T)), ",",
                    shQuote(format(end.time, usetz=T)), ",",
                    "get.pair_id(",shQuote(pair),"), " ,
                    "get.exchange_id(", shQuote(exchange), ") ",
                    " )) select get._in_milliseconds(timestamp) as timestamp, side,  bps_level, price, volume from depth_summary ",
                    # this is a workaround for the inability of R to handle microseconds in POSIXct
                    " where r=1 -- if rounded to milliseconds 'microtimestamp's are not unique, we'll take the LasT one and will drop the first silently order by 1, 2 desc")
  else
    query <- paste0(" with depth_summary as ( select timestamp, price, volume, side, bps_level, rank() over (partition by get._in_milliseconds(timestamp) order by timestamp desc) as r ",
                    " from get.depth_summary(",
                    shQuote(format(start.time, usetz=T)), ",",
                    shQuote(format(end.time, usetz=T)), ",",
                    "get.pair_id(",shQuote(pair),"), " ,
                    "get.exchange_id(", shQuote(exchange), "), ",
                    "p_frequency := ", shQuote(paste0(frequency, " seconds ")),
                    " )) select get._in_milliseconds(timestamp) as timestamp, side,  bps_level, price, volume from depth_summary ",
                    # this is a workaround for the inability of R to handle microseconds in POSIXct
                    " where r=1 -- if rounded to milliseconds 'microtimestamp's are not unique, we'll take the LasT one and will drop the first silently order by 1, 2 desc")
  flog.debug(query, name=packageName())
  df <- DBI::dbGetQuery(conn, query)
  df$timestamp <- as.POSIXct(as.numeric(df$timestamp)/1000, origin="1970-01-01")
  df

}


#' @export
order_book <- function(con, tp, exchange, pair, max.levels = NA, bps.range = NA, min.bid = NA, max.ask = NA, tz='UTC') {

  conn=con$con()

  if(is.character(tp)) start.time <- ymd_hms(start.time)

  stopifnot(inherits(tp, 'POSIXt'))

  flog.debug(paste0("order_book(con,", format(tp, usetz=T), "," , exchange, ", ", pair,")" ), name=packageName())

  tzone <- tz

  if (is.na(max.levels)) max.levels <- "NULL"
  if (is.na(bps.range)) bps.range <- "NULL"
  if (is.na(min.bid)) min.bid <- "NULL"
  if (is.na(max.ask)) max.ask <- "NULL"


  query <- paste0("select ts, \"timestamp\", id, price, volume, liquidity, bps, side, \"exchange.timestamp\"
                   from get.order_book(",
                  shQuote(format(tp, usetz=T)), ",",
                  "get.pair_id(",shQuote(pair),"), " ,
                  "get.exchange_id(", shQuote(exchange), "), ",
                  max.levels,  ",",
                  bps.range,  ",",
                  min.bid,  ",",
                  max.ask, ")")
  flog.debug(query, name=packageName())
  full_book <- DBI::dbGetQuery(conn, query)
  cols <- c("id","timestamp", "exchange.timestamp", "price", "volume", "liquidity", "bps")
  bids <- full_book[which(full_book$side == 'b'), cols ]
  asks <- full_book[which(full_book$side == 's'), cols ]
  ts <- full_book$ts[1]
  ts <- with_tz(ts, tzone)
  list(timestamp=ts, asks=asks, bids=bids)
}




#' @export
export <- function(con, start.time, end.time, exchange, pair, file = "events.csv") {
  conn=con$con()

  start.time <- format(start.time, usetz=T)
  end.time <- format(end.time, usetz=T)

  query <- paste0(" select * from get.export(", shQuote(start.time),
                  ", ",
                  shQuote(format(end.time, usetz=T)), ",",
                  "get.pair_id(",shQuote(pair),"), " ,
                  "get.exchange_id(", shQuote(exchange), ") ",
                  ") order by timestamp")
  flog.debug(query, name=packageName())
  events <- DBI::dbGetQuery(conn, query)
  write.csv(events, file = file, row.names = FALSE)
}


#' @export
draws <- function(x, ...) {
  UseMethod("draws")
}


#' @export
#' @method draws data.table
draws.data.table <- function(spread.changes, gamma_0, theta, draw.type='mid-price', skip.crossed = TRUE, tz='UTC') {

  if('pair' %in% colnames(spread.changes))
    if(skip.crossed)
      result <- spread.changes[best.bid.price <= best.ask.price, draws_from_spread(timestamp,
                                                   switch(draw.type,
                                                          "mid-price"=(best.bid.price + best.ask.price)/2,
                                                          "bid"=best.bid.price,
                                                          "ask"=best.ask.price
                                                   ),
                                                   gamma_0,
                                                   theta), by=.(pair, exchange) ]
    else
      result <- spread.changes[, draws_from_spread(timestamp,
                                                   switch(draw.type,
                                                          "mid-price"=(best.bid.price + best.ask.price)/2,
                                                          "bid"=best.bid.price,
                                                          "ask"=best.ask.price
                                                   ),
                                                   gamma_0,
                                                   theta), by=.(pair, exchange) ]

  else {
    if(skip.crossed)
      result <- spread.changes[best.bid.price <= best.ask.price, draws_from_spread(timestamp,
                                         switch(draw.type,
                                                "mid-price"=(best.bid.price + best.ask.price)/2,
                                                "bid"=best.bid.price,
                                                "ask"=best.ask.price
                                         ),
                                         gamma_0,
                                         theta),]
    else
      result <- spread.changes[, draws_from_spread(timestamp,
                                                   switch(draw.type,
                                                          "mid-price"=(best.bid.price + best.ask.price)/2,
                                                          "bid"=best.bid.price,
                                                          "ask"=best.ask.price
                                                   ),
                                                   gamma_0,
                                                   theta),]
    setDT(result)
  }
  cols <- c("timestamp", "draw.end")
  result[, (cols) := lapply(.SD, lubridate::as_datetime, tz=tz), .SDcols=cols ]
  setcolorder(result, c("timestamp","draw.end","start.price", "end.price", "draw.size", "draw.speed", "pair", "exchange"))
  result
}




#' @export
draws.connection <- function(con, start.time, end.time, exchanges, pairs, gamma_0, theta=0, draw.type='mid-price', frequency=NULL, skip.crossed=TRUE,  tz='UTC') {

  conn=con$con()

  if(is.character(start.time)) start.time <- ymd_hms(start.time)
  if(is.character(end.time)) end.time <- ymd_hms(end.time)

  stopifnot(inherits(start.time, 'POSIXt') & inherits(end.time, 'POSIXt'))
  stopifnot(is.null(frequency) || is.numeric(frequency))
  stopifnot(is.null(frequency) || frequency < 3600 || (frequency > 60 && frequency %% 60 == 0) || frequency < 60 && frequency > 0)

  if(is.null(frequency))
    flog.debug(paste0("draws(conn,", shQuote(format(start.time, usetz=T)), "," , shQuote(format(end.time, usetz=T)),",", paste0("c(", paste0(shQuote(exchanges), collapse=","),")"), ", ", paste0("c(", paste0(shQuote(pairs), collapse=","),")"),")" ), name=packageName())
  else
    flog.debug(paste0("draws(conn,", shQuote(format(start.time, usetz=T)), "," , shQuote(format(end.time, usetz=T)),",", paste0("c(", paste0(shQuote(exchanges), collapse=","),")"), ", ", paste0("c(", paste0(shQuote(pairs), collapse=","),")"), ",", frequency, ")" ), name=packageName())

  tzone <- tz

  # Convert to UTC, so internally only UTC is used
  start.time <- with_tz(start.time, tz='UTC')
  end.time <- with_tz(end.time, tz='UTC')


  result <- rbindlist(lapply(
    do.call(c,
            lapply(exchanges,
                   function(e) {
                     lapply(pairs, function(p) list(exchange=e, pair=p) )
                   }
                   )
            ),
    function(i) {
      draws <- .draws(conn, start.time, end.time,  i$exchange, i$pair, gamma_0, theta, draw.type, frequency, skip.crossed)
      if(nrow(draws) > 0) {
        draws[, c("timestamp","draw.end","pair", "exchange") := .( with_tz(timestamp, tzone), with_tz(draw.end, tzone), ..i$pair, ..i$exchange)]
      }
      draws
    }
    )
  )
  setcolorder(result, c("timestamp","draw.end","start.price", "end.price", "draw.size", "draw.speed", "pair", "exchange"))
  result
}

.draws <- function(conn, start.time, end.time, exchange, pair, gamma_0, theta, draw.type, frequency = NULL, skip.crossed=TRUE) {

  if(is.null(frequency))
    query <- paste0(" select timestamp, \"draw.end\", \"start.price\",",
                    "\"end.price\", \"draw.size\", \"draw.speed\" FROM get.draws(",
                    shQuote(format(start.time, usetz=T)), ",",
                    shQuote(format(end.time, usetz=T)), ",",
                    shQuote(draw.type), ",",
                    "get.pair_id(",shQuote(pair),"), " ,
                    "get.exchange_id(", shQuote(exchange), ") , ",
                    "p_gamma_0 := ", gamma_0, ",",
                    "p_theta := ",  theta, ",",
                    "p_skip_crossed :=", skip.crossed,
                    ") order by 1")
  else
    query <- paste0(" select \"timestamp\", \"draw.end\", \"start.price\",",
                    "\"end.price\", \"draw.size\", \"draw.speed\" FROM get.draws(",
                    shQuote(format(start.time, usetz=T)), ",",
                    shQuote(format(end.time, usetz=T)), ",",
                    shQuote(draw.type), ",",
                    "get.pair_id(",shQuote(pair),"), " ,
                    "get.exchange_id(", shQuote(exchange), "),",
                    "p_gamma_0 := ", gamma_0, ",",
                    "p_theta := ",  theta, ",",
                    "p_frequency :=", shQuote(paste0(frequency, " seconds ")), ", " ,
                    "p_skip_crossed :=", skip.crossed,
                    ") order by 1")
  flog.debug(query, name=packageName())
  draws <- DBI::dbGetQuery(conn, query)
  setDT(draws)

  if(nrow(draws) > 0) {
    draws[, c("timestamp", "draw.end") := .(as.POSIXct(timestamp/1000000.0, origin="2000-01-01"),
                                        as.POSIXct(draw.end/1000000.0, origin="2000-01-01")) ]
  }
  draws
}


#' @export
intervals <- function(con, start.time=NULL, end.time=NULL, exchange = NULL, pair = NULL, tz='UTC') {
  conn=con$con()


  if(!is.null(start.time)) {
    if(is.character(start.time)) start.time <- ymd_hms(start.time)
    stopifnot(inherits(start.time, 'POSIXt'))
    start.time <- with_tz(start.time, tz='UTC')
    start.time <- shQuote(format(start.time,"%Y-%m-%d %H:%M:%S%z")) # ISO 8601 format which is understood by both: Postgres and ymd_hms()
  }
  else
    start.time <- "NULL"

  if(!is.null(end.time)) {
    if(is.character(end.time)) end.time <- ymd_hms(end.time)
    stopifnot(inherits(end.time, 'POSIXt'))
    end.time <- with_tz(end.time, tz='UTC')
    end.time <- shQuote(format(end.time,"%Y-%m-%d %H:%M:%S%z"))
  }
  else
    end.time <- "NULL"

  if(!is.null(pair)) pair <- paste0(" get.pair_id(",shQuote(pair),") ") else pair <- "NULL"
  if(!is.null(exchange)) exchange <- paste0(" get.exchange_id(", shQuote(exchange), ") ") else exchange <- "NULL"


  pmap_dfr(tibble(pair, exchange),function(pair, exchange) {

    # Various PostgreSQL-drivers in R are not able to handle timezone conversion correctly/consistently
    # So we use EXTRACT epoch and then convert the epoch to POSIXct on the R side

    query <- paste0("select exchange_id, pair_id, extract(epoch from interval_start) as interval_start, extract(epoch from interval_end) as interval_end,",
                      " case when events then 'G'  else 'R' end as c, exchange, pair, extract(epoch from era) as era from get.events_intervals( ",
                    " p_pair_id => ", pair,
                    ", ",
                    " p_exchange_id => ", exchange,
                    ")",
                    " where interval_end > coalesce( ", start.time, " , interval_end - '1 second'::interval ) ",
                    "   and interval_start < coalesce( ", end.time, " , interval_start + '1 second'::interval ) "
    )

    flog.debug(query, name=packageName())
    intervals <- DBI::dbGetQuery(conn, query)

    intervals <- intervals %>%
      mutate(interval_start=as.POSIXct(interval_start, origin="1970-01-01"),
             interval_end=as.POSIXct(interval_end, origin="1970-01-01"),
             era=as.POSIXct(era, origin="1970-01-01")
      )

    if(start.time != "NULL") {
      start.time <- ymd_hms(start.time)
      intervals <- intervals %>% mutate(interval_start=if_else(interval_start < start.time, start.time, interval_start))
    }
    if(end.time != "NULL") {
      end.time <- ymd_hms(end.time)
      intervals <- intervals %>% mutate(interval_end=if_else(interval_end > end.time, end.time, interval_end))
    }

    intervals$interval_start <- with_tz(intervals$interval_start, tz)
    intervals$interval_end <- with_tz(intervals$interval_end, tz)
    intervals$era <- with_tz(intervals$era, tz)

    intervals
  } )

}
