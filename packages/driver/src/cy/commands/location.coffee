_ = require("lodash")
Promise = require("bluebird")

$Cy = require("../../cypress/cy")
$Location = require("../../cypress/location")
$Log = require("../../cypress/log")
utils = require("../../cypress/utils")

$Cy.extend({
  __location: (win) ->
    win.location.toString()

  _getLocation: (key, win) ->
    try
      remoteUrl = @__location(win ? @privateState("window"))
      location  = $Location.create(remoteUrl)

      if key
        location[key]
      else
        location
    catch e
      ""
})

module.exports = (Cypress, Commands) ->
  Commands.addAll({
    url: (options = {}) ->
      _.defaults options, {log: true}

      if options.log isnt false
        options._log = $Log.command
          message: ""

      getHref = =>
        @_getLocation("href")

      do resolveHref = =>
        Promise.try(getHref).then (href) =>
          @verifyUpcomingAssertions(href, options, {
            onRetry: resolveHref
          })

    hash: (options = {}) ->
      _.defaults options, {log: true}

      if options.log isnt false
        options._log = $Log.command
          message: ""

      getHash = =>
        @_getLocation("hash")

      do resolveHash = =>
        Promise.try(getHash).then (hash) =>
          @verifyUpcomingAssertions(hash, options, {
            onRetry: resolveHash
          })

    location: (key, options) ->
      ## normalize arguments allowing key + options to be undefined
      ## key can represent the options
      if _.isObject(key) and _.isUndefined(options)
        options = key

      options ?= {}

      _.defaults options, {log: true}

      getLocation = =>
        location = @_getLocation()

        ret = if _.isString(key)
          ## use existential here because we only want to throw
          ## on null or undefined values (and not empty strings)
          location[key] ?
            utils.throwErrByPath("location.invalid_key", { args: { key } })
        else
          location

      if options.log isnt false
        options._log = $Log.command
          message: key ? ""

      do resolveLocation = =>
        Promise.try(getLocation).then (ret) =>
          @verifyUpcomingAssertions(ret, options, {
            onRetry: resolveLocation
          })
  })