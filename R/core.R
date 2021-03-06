rga$methods(
    list(
        getData = function(ids, start.date = format(Sys.Date() - 8, "%Y-%m-%d"),
                           end.date = format(Sys.Date() - 1, "%Y-%m-%d"), date.format = "%Y-%m-%d",
                           metrics = "ga:users,ga:sessions,ga:pageviews", dimensions = "ga:date",
                           sort = "", filters = "", segment = "", fields = "",
                           start = 1, max, messages = TRUE,  batch, walk = FALSE,
                           output.raw, output.formats, return.url = FALSE, rbr = FALSE, envir = .GlobalEnv) {

            if (missing(ids)) {
                stop("please enter a profile id")
            }

            if (missing(batch) || batch == FALSE) {
                isBatch <- FALSE
                if (missing(max)) {
                    # standard
                    max <- 1000
                }
            } else {
                isBatch <- TRUE
                if (!is.numeric(batch)) {
                    if (!missing(max) && max < 10000) {
                        # no need
                        batch <- max
                    } else {
                        # max batch size
                        batch <- 10000
                    }
                } else {
                    if (batch > 10000) {
                        # as per https://developers.google.com/analytics/devguides/reporting/core/v2/gdataReferenceDataFeed#maxResults
                        stop("batch size can max be set to 10000")
                    }
                }

                if (missing(max)) {
                    adjustMax <- TRUE
                    # arbitrary target, adjust later
                    max <- 10000
                } else {
                    adjustMax <- FALSE
                }
            }

            # ensure that profile id begings with 'ga:'
            if (!grepl("ga:", ids)) {
                ids <- paste("ga:", ids, sep = "")
            }

            # remove whitespaces from metrics and dimensions
            metrics <- gsub("\\s", "", metrics)
            dimensions <- gsub("\\s", "", dimensions)

            # build url with variables
            url <- "https://www.googleapis.com/analytics/v3/data/ga"
            query <- paste(paste("access_token", .self$getToken()$access_token, sep = "="),
                           paste("ids", ids, sep = "="),
                           paste("start-date", start.date, sep = "="),
                           paste("end-date", end.date, sep = "="),
                           paste("metrics", metrics, sep = "="),
                           paste("dimensions", dimensions, sep = "="),
                           paste("start-index", start, sep = "="),
                           paste("max-results", max, sep = "="),
                           sep = "&")

            if (sort != "") {
                query <- paste(query, paste("sort", sort, sep = "="), sep = "&")
            }
            if (segment != "") {
                query <- paste(query, paste("segment", segment, sep = "="), sep = "&")
            }
            if (fields != "") {
                query <- paste(query, paste("fields", fields, sep = "="), sep = "&")
            }
            if (filters != "") {
                # available operators
                ops <- c("==", "!=", ">", "<", ">=", "<=", "=@", "!@", "=-", "!-", "\\|\\|", "&&", "OR", "AND")
                # make pattern for gsub
                opsw <- paste("(\\ )+(", paste(ops, collapse = "|"), ")(\\ )+", sep = "")
                # remove whitespaces around operators
                filters <- gsub(opsw, "\\2", filters)
                # replace logical operators
                filters <- gsub("OR|\\|\\|", ",", filters)
                filters <- gsub("AND|&&", ";", filters)
                query <- paste(query, paste("filters", curlEscape(filters), sep = "="), sep = "&", collapse = "")
            }

            url <- paste(url, query = query, sep = "?")

            if (return.url) {
                return(url)
            }

            # thanks to Schaun Wheeler this will not provoke the weird SSL-bug
            if (.Platform$OS.type == "windows") {
                options(RCurlOptions = list(
                    verbose = FALSE,
                    capath = system.file("CurlSSL", "cacert.pem",
                                         package = "RCurl"), ssl.verifypeer = FALSE))
            }

            # get data and convert from json to list-format
            # switched to use httr and jsonlite
            request <- GET(url)
            ga.data <- jsonlite::fromJSON(content(request, "text"))

            # possibility to extract the raw data
            if (!missing(output.raw)) {
                assign(output.raw, ga.data, envir = envir)
            }

            # output error and stop
            if (!is.null(ga.data$error)) {
                stop(paste("error in fetching data: ", ga.data$error$message, sep = ""))
            }

            if (ga.data$containsSampledData == "TRUE") {
                isSampled <- TRUE
                if (!walk) {
                    message("Notice: Data set contains sampled data")
                }
            } else {
                isSampled <- FALSE
            }

            if (isSampled && walk) {
                return(.self$getDataInWalks(total = ga.data$totalResults, max = max, batch = batch,
                                            ids = ids, start.date = start.date, end.date = end.date, date.format = date.format,
                                            metrics = metrics, dimensions = dimensions, sort = sort, filters = filters,
                                            segment = segment, fields = fields, envir = envir))
            }

            # check if all data is being extracted
            if (nrow(ga.data$rows) < ga.data$totalResults && (messages || isBatch)) {
                if (!isBatch) {
                    message(paste("Only pulling", length(ga.data$rows), "observations of", ga.data$totalResults, "total (set batch = TRUE to get all observations)"))
                } else {
                    if (adjustMax) {
                        max <- ga.data$totalResults
                    }
                    message(paste("Pulling", max, "observations in batches of", batch))
                    # pass variables to batch-function
                    return(.self$getDataInBatches(total = ga.data$totalResults, max = max, batchSize = batch,
                                                  ids = ids, start.date = start.date, end.date = end.date, date.format = date.format,
                                                  metrics = metrics, dimensions = dimensions, sort = sort, filters = filters,
                                                  segment = segment, fields = fields, envir = envir))
                }
            }

            # get column names
            ga.headers <- ga.data$columnHeaders
            # remove ga: from column headers
            ga.headers$name <- sub("ga:", "", ga.headers$name)

            # did not return any results
            if (!inherits(ga.data$rows, "matrix") && !rbr) {
                stop(paste("no results:", ga.data$totalResults))
            } else if (!inherits(ga.data$rows, "matrix") && rbr) {
                # return data.frame with NA, if row-by-row setting is true
                row <- as.data.frame(matrix(rep(NA, length(ga.headers$name), nrow = 1)))
                names(row) <- ga.headers$name
                return(row)
            }

            # convert to data.frame
            ga.data.df <- as.data.frame(ga.data$rows, stringsAsFactors = FALSE)
            # insert column names
            names(ga.data.df) <- ga.headers$name

            # find formats
            formats <- ga.headers

            # convert to r friendly
            formats$dataType[formats$dataType %in% c("INTEGER", "PERCENT", "TIME", "CURRENCY", "FLOAT")] <- "numeric"
            formats$dataType[formats$dataType == "STRING"] <- "character"
            # addition rules
            formats$dataType[formats$name %in% c("latitude", "longitude")] <- "numeric"
            formats$dataType[formats$name %in% c("year", "month", "week", "day", "hour", "minute", "nthMonth", "nthWeek", "nthDay", "nthHour", "nthMinute", "dayOfWeek", "sessionDurationBucket", "visitLength", "daysSinceLastVisit", "daysSinceLastSession", "visitCount", "sessionCount", "sessionsToTransaction", "daysToTransaction")] <- "ordered"
            formats$dataType[formats$name == "date"] <- "Date"

            if ("date" %in% ga.headers$name) {
                ga.data.df$date <- format(as.Date(ga.data.df$date, "%Y%m%d"), date.format)
            }

            # looping through columns and setting classes
            for (i in 1:nrow(formats)) {
                column <- formats$name[i]
                class <- formats$dataType[[i]]
                if (!exists(paste("as.", class, sep = ""), mode = "function")) {
                    stop(paste("can't find function for class", class))
                } else {
                    as.fun <- match.fun(paste("as.", class, sep = ""))
                }
                if (class == "ordered") {
                    ga.data.df[[column]] <- as.numeric(ga.data.df[[column]])
                }
                ga.data.df[[column]] <- as.fun(ga.data.df[[column]])
            }

            # mos-def optimize
            if (!missing(output.formats)) {
                assign(output.formats, formats, envir = envir)
            }

            # and we're done
            return(ga.data.df)
        },
        getFirstDate = function(ids) {
            first <- .self$getData(ids, start.date = "2005-01-01", filters = "ga:sessions!=0", max = 1, messages = FALSE)
            return(first$date)
        },
        getDataInBatches = function(batchSize, total, ids, start.date, end.date, date.format,
                                    metrics, max, dimensions, sort, filters, segment, fields, envir) {
            runs.max <- ceiling(max/batchSize)
            chunk.list <- vector("list", runs.max)
            for (i in 0:(runs.max - 1)) {
                start <- i * batchSize + 1
                end <- start + batchSize - 1
                # adjust batch size if we're pulling the last batch
                if (end > max) {
                    batchSize <- max - batchSize
                    end <- max
                }

                message(paste("Run (", i + 1, "/", runs.max, "): observations [", start, ";", end, "]. Batch size: ", batchSize, sep = ""))
                chunk <- .self$getData(ids = ids, start.date = start.date, end.date = end.date, metrics = metrics, dimensions = dimensions, sort = sort,
                                       filters = filters, segment = segment, fields = fields, date.format = date.format, envir = envir, messages = FALSE, return.url = FALSE,
                                       batch = FALSE, start = start, max = batchSize)
                message(paste("Received:", nrow(chunk), "observations"))
                chunk.list[[i + 1]] <- chunk
            }
            return(do.call(rbind, chunk.list, envir = envir))
        },
        getDataInWalks = function(total, max, batch, ids, start.date, end.date, date.format,
                                  metrics, dimensions, sort, filters, segment, fields, envir) {
            # this function will extract data day-by-day (to avoid sampling)
            walks.max <- ceiling(as.numeric(difftime(end.date, start.date, units = "days")))
            chunk.list <- vector("list", walks.max + 1)

            for (i in 0:(walks.max)) {
                date <- format(as.POSIXct(start.date) + days(i), "%Y-%m-%d")

                message(paste("Run (", i + 1, "/", walks.max + 1, "): for date ", date, sep = ""))
                chunk <- .self$getData(ids = ids, start.date = date, end.date = date, date.format = date.format,
                                       metrics = metrics, dimensions = dimensions, sort = sort, filters = filters,
                                       segment = segment, fields = fields, envir = envir, max = max,
                                       rbr = TRUE, messages = FALSE, return.url = FALSE, batch = batch)
                message(paste("Received:", nrow(chunk), "observations"))
                chunk.list[[i + 1]] <- chunk
            }

            return(do.call(rbind, chunk.list, envir = envir))
        }
    )
)
