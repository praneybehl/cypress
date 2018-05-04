_               = require("lodash")
mime            = require("mime")
path            = require("path")
bytes           = require("bytes")
Promise         = require("bluebird")
dataUriToBuffer = require("data-uri-to-buffer")
Jimp            = require("jimp")
debug           = require("debug")("cypress:server:screenshot")
fs              = require("./util/fs")
glob            = require("./util/glob")

RUNNABLE_SEPARATOR = " -- "
invalidCharsRe     = /[^0-9a-zA-Z-_\s]/g

## TODO: when we parallelize these builds we'll need
## a semaphore to access the file system when we write
## screenshots since its possible two screenshots with
## the same name will be written to the file system

Jimp.prototype.getBuffer = Promise.promisify(Jimp.prototype.getBuffer)

isBlack = (rgba) ->
  "#{rgba.r}#{rgba.g}#{rgba.b}" is "000"

isWhite = (rgba) ->
  "#{rgba.r}#{rgba.g}#{rgba.b}" is "255255255"

hasHelperPixels = (image) ->
  topLeft = Jimp.intToRGBA(image.getPixelColor(0, 0))
  topLeftRight = Jimp.intToRGBA(image.getPixelColor(1, 0))
  topLeftDown = Jimp.intToRGBA(image.getPixelColor(0, 1))
  topRight = Jimp.intToRGBA(image.getPixelColor(image.bitmap.width, 0))
  bottomLeft = Jimp.intToRGBA(image.getPixelColor(0, image.bitmap.height))
  bottomRight = Jimp.intToRGBA(image.getPixelColor(image.bitmap.width, image.bitmap.height))

  return (
    isBlack(topLeft) and
    isWhite(topLeftRight) and
    isWhite(topLeftDown) and
    isWhite(topRight) and
    isBlack(bottomRight) and
    isWhite(bottomLeft)
  )

captureAndCheck = (data, automate, condition) ->
  tries = 0
  do attempt = ->
    tries++
    debug("capture and check attempt ##{tries}")

    automate(data)
    .then (dataUrl) ->
      debug("received screenshot data from automation layer")

      Jimp.read(dataUriToBuffer(dataUrl))
    .then (image) ->
      debug("read buffer to image #{image.bitmap.width} x #{image.bitmap.height}")

      if tries >= 10 or condition(data, image)
        return image
      else
        attempt()

isAppOnly = (data) ->
  data.capture is "app" or data.capture is "fullpage"

isMultipart = (data) ->
  _.isNumber(data.current) and _.isNumber(data.total)

crop = (image, dimensions, pixelRatio = 1) ->
  dimensions = _.transform dimensions, (result, value, dimension) ->
    result[dimension] = value * pixelRatio

  x = Math.min(dimensions.x, image.bitmap.width - 1)
  y = Math.min(dimensions.y, image.bitmap.height - 1)
  width = Math.min(dimensions.width, image.bitmap.width - x)
  height = Math.min(dimensions.height, image.bitmap.height - y)
  debug("crop: from #{image.bitmap.width} x #{image.bitmap.height}")
  debug("        to #{width} x #{height} at (#{x}, #{y})")

  image.crop(x, y, width, height)

pixelCondition = (data, image) ->
  hasPixels = hasHelperPixels(image)
  return (
    (isAppOnly(data) and not hasPixels) or
    (not isAppOnly(data) and hasPixels)
  )

multipartImages = []

clearMultipartState = ->
  multipartImages = []

compareLast = (data, image) ->
  ## ensure the previous image isn't the same, which might indicate the
  ## page has not scrolled yet
  previous = _.last(multipartImages)
  if not previous
    return true
  debug("compare", previous.image.hash(), "vs", image.hash())
  return previous.image.hash() isnt image.hash()

multipartCondition = (data, image) ->
  if data.current is 1
    pixelCondition(data, image) and compareLast(data, image)
  else
    compareLast(data, image)

stitchScreenshots = (pixelRatio) ->
  width = Math.min(_.map(multipartImages, "data.clip.width")...)
  height = _.sumBy(multipartImages, "data.clip.height")

  debug("stitch #{multipartImages.length} images together")

  fullImage = new Jimp(width, height)
  heightMarker = 0
  _.each multipartImages, ({ data, image }) ->
    croppedImage = image.clone()
    crop(croppedImage, data.clip, pixelRatio)

    debug("stitch: add image at (0, #{heightMarker})")

    fullImage.composite(croppedImage, 0, heightMarker)
    heightMarker += croppedImage.bitmap.height

  return { image: fullImage, pixelRatio }

module.exports = {
  crop

  clearMultipartState

  copy: (src, dest) ->
    fs
    .copyAsync(src, dest, {overwrite: true})
    .catch {code: "ENOENT"}, ->
      ## dont yell about ENOENT errors

  get: (screenshotsFolder) ->
    ## find all files in all nested dirs
    screenshotsFolder = path.join(screenshotsFolder, "**", "*")

    glob(screenshotsFolder, {nodir: true})

  capture: (data, automate) ->
    condition = if isMultipart(data) then multipartCondition else pixelCondition

    captureAndCheck(data, automate, condition)
    .then (image) ->
      pixelRatio = image.bitmap.width / data.viewport.width
      debug("pixel ratio is", pixelRatio)

      if isMultipart(data)
        debug("multi-part #{data.current}/#{data.total}")

      if isMultipart(data) and data.total > 1
        ## keep previous screenshot partials around b/c if two screenshots are
        ## taken in a row, the UI might not be caught up so we need something
        ## to compare the new one to
        ## only clear out once we're ready to save the first partial for the
        ## screenshot currently being taken
        if data.current is 1
          clearMultipartState()

        multipartImages.push({ data, image })

        if data.current is data.total
          return stitchScreenshots(pixelRatio)
        else
          return {}

      if isAppOnly(data) or isMultipart(data)
        crop(image, data.clip, pixelRatio)

      return { image, pixelRatio }
    .then ({ image, pixelRatio }) ->
      if image and data.userClip
        crop(image, data.userClip, pixelRatio)

      return image

  save: (data, image, screenshotsFolder) ->
    type = image.getMIME()

    name = data.name ? data.titles.join(RUNNABLE_SEPARATOR)
    name = name.replace(invalidCharsRe, "")
    name = [name, mime.extension(type)].join(".")

    pathToScreenshot = path.join(screenshotsFolder, name)

    debug("save", pathToScreenshot)

    image.getBuffer(Jimp.AUTO)
    .then (buffer) ->
      fs.outputFileAsync(pathToScreenshot, buffer)
    .then ->
      fs.statAsync(pathToScreenshot).get("size")
    .then (size) ->
      {
        size:   bytes(size, {unitSeparator: " "})
        path:   pathToScreenshot
        width:  image.bitmap.width
        height: image.bitmap.height
      }

}
