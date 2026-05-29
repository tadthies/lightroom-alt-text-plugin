local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrHttp = import 'LrHttp'
local LrFileUtils = import 'LrFileUtils'
local LrExportSession = import 'LrExportSession'
local LrStringUtils = import 'LrStringUtils'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope = import 'LrProgressScope'
local LrLogger = import 'LrLogger'

local logger = LrLogger('AltTextPlugin')
logger:enable("logfile")

local prefs = LrPrefs.prefsForPlugin()

local function loadModule(fileName)
    local ok, result = pcall(dofile, LrPathUtils.child(_PLUGIN.path, fileName))
    if not ok then
        LrDialogs.message(
            "Alt Text Generator failed to load.",
            "Could not load " .. fileName .. ": " .. tostring(result),
            "critical"
        )
        error("Failed to load " .. fileName)
    end
    return result
end

local config = loadModule('config.lua')
local json = loadModule('dkjson.lua')

local function validateMetadataField(field)
    for _, item in ipairs(config.METADATA_FIELDS) do
        if item.value == field then
            return field
        end
    end
    return config.DEFAULT_METADATA_FIELD
end

local function sanitizeForLog(str)
    local apiKey = prefs.claudeApiKey
    if apiKey and apiKey ~= "" and str then
        return str:gsub(apiKey, "[REDACTED]")
    end
    return str or ""
end

local function resizePhoto(photo, progressScope)
    progressScope:setCaption("Resizing photo...")

    -- Export into a per-photo temp subfolder keyed on the photo's unique local
    -- identifier, so two selected photos that share a filename can never collide
    -- and stale files from earlier runs can't make Lightroom append a "-2" suffix.
    local tempDir = LrPathUtils.child(
        LrPathUtils.getStandardFilePath('temp'),
        'alttext-' .. tostring(photo.localIdentifier)
    )
    if LrFileUtils.exists(tempDir) then
        LrFileUtils.delete(tempDir)
    end
    LrFileUtils.createAllDirectories(tempDir)

    local exportSettings = {
        LR_export_destinationType = 'specificFolder',
        LR_export_destinationPathPrefix = tempDir,
        LR_export_useSubfolder = false,
        LR_format = 'JPEG',
        LR_jpeg_quality = 0.8,
        LR_minimizeEmbeddedMetadata = true,
        LR_outputSharpeningOn = false,
        LR_size_doConstrain = true,
        LR_size_maxHeight = 1024,
        LR_size_maxWidth = 1024,
        LR_size_resizeType = 'wh',
        LR_size_units = 'pixels',
    }

    local exportSession = LrExportSession({
        photosToExport = {photo},
        exportSettings = exportSettings
    })

    for _, rendition in exportSession:renditions() do
        local success, path = rendition:waitForRender()
        if success then
            return path
        end
    end

    return nil
end

local function encodePhotoToBase64(filePath, progressScope)
    progressScope:setCaption("Encoding photo...")

    local file = io.open(filePath, "rb")
    if not file then
        return nil
    end

    local data = file:read("*all")
    file:close()

    return LrStringUtils.encodeBase64(data)
end

local function requestAltTextFromClaude(imageBase64, progressScope)
    progressScope:setCaption("Requesting alt text from Claude...")

    local url = "https://api.anthropic.com/v1/messages"
    local headers = {
        { field = "Content-Type", value = "application/json" },
        { field = "x-api-key", value = prefs.claudeApiKey },
        { field = "anthropic-version", value = config.ANTHROPIC_VERSION },
    }

    local body = {
        model = config.MODEL,
        max_tokens = config.MAX_TOKENS,
        system = config.INSTRUCTIONS,
        messages = {
            {
                role = "user",
                content = {
                    {
                        type = "image",
                        source = {
                            type = "base64",
                            media_type = "image/jpeg",
                            data = imageBase64
                        }
                    },
                    {
                        type = "text",
                        text = "Please generate alt text for this image."
                    }
                }
            }
        }
    }

    local bodyJson = json.encode(body)
    local response, hdrs = LrHttp.post(url, bodyJson, headers)

    if not response then
        -- On a transport-level failure LrHttp.post returns nil plus an info table
        -- whose "error" entry describes what went wrong (timeout, bad host, etc.).
        local detail = "no response"
        if hdrs and hdrs.error then
            detail = hdrs.error.name or hdrs.error.errorCode or detail
        end
        logger:trace("Claude API request failed: " .. detail)
        return nil, "Could not reach the Claude API: " .. detail
    end

    local ok, decoded = pcall(json.decode, response)
    if not ok then
        logger:trace("Failed to parse Claude response: " .. sanitizeForLog(response))
        return nil, "Invalid response from Claude"
    end

    if decoded.error and decoded.error.message then
        logger:trace("Claude API error: " .. sanitizeForLog(json.encode(decoded, { indent = true })))
        return nil, "Claude error: " .. decoded.error.message
    end

    local content = decoded.content or {}
    for _, block in ipairs(content) do
        if block.type == "text" and block.text then
            local trimmed = LrStringUtils.trimWhitespace(block.text)
            if trimmed ~= "" then
                return trimmed
            end
        end
    end

    logger:trace("Claude returned unexpected response: " .. sanitizeForLog(json.encode(decoded, { indent = true })))
    return nil, "Claude returned an unexpected response"
end

local function generateAltTextForPhoto(photo, photoName, progressScope)
    local metadataField = validateMetadataField(prefs.metadataField)

    local function fail(err)
        logger:trace("Alt text failed for " .. tostring(photoName) .. ": " .. tostring(err))
        return false, err
    end

    local resizedFilePath = resizePhoto(photo, progressScope)
    if not resizedFilePath then
        return fail("Failed to resize photo")
    end

    local base64Image = encodePhotoToBase64(resizedFilePath, progressScope)
    LrFileUtils.delete(resizedFilePath)

    if not base64Image then
        return fail("Failed to encode photo")
    end

    local altText, err = requestAltTextFromClaude(base64Image, progressScope)

    if altText then
        -- setRawMetadata is synchronous, so it's safe to pcall (unlike the
        -- yielding SDK calls above). This keeps a single bad photo — e.g. an
        -- unwritable field — from aborting the entire batch.
        local wrote = false
        photo.catalog:withWriteAccessDo("Set Alt Text", function()
            wrote = pcall(function()
                photo:setRawMetadata(metadataField, altText)
            end)
        end)
        if wrote then
            return true
        end
        return fail("Failed to save alt text")
    end

    return fail(err or "Failed to generate alt text")
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("GenerateAltText", function(context)
        local catalog = LrApplication.activeCatalog()
        local selectedPhotos = catalog:getTargetPhotos()

        if #selectedPhotos == 0 then
            LrDialogs.message("Please select at least one photo.")
            return
        end

        local apiKey = prefs.claudeApiKey
        if not apiKey or apiKey == "" then
            LrDialogs.message("Your Claude API key is missing. Please set it up in the plugin manager.")
            return
        end

        -- Re-entrancy guard: prevent a second run from starting while one is in
        -- progress. The flag lives in prefs (each menu click re-runs this file
        -- fresh, so a local variable wouldn't persist) and is cleared by a cleanup
        -- handler so it resets even if the task errors or is canceled.
        if prefs.isRunning then
            LrDialogs.message("Alt text generation is already running.")
            return
        end
        prefs.isRunning = true
        context:addCleanupHandler(function()
            prefs.isRunning = false
        end)

        local metadataField = validateMetadataField(prefs.metadataField)
        local skipExisting = prefs.skipExisting or false

        local progressScope = LrProgressScope({
            title = "Generating Alt Text",
            functionContext = context,
        })

        local successes = 0
        local failures = 0
        local skipped = 0
        local errors = {}

        for i, photo in ipairs(selectedPhotos) do
            if progressScope:isCanceled() then
                break
            end

            progressScope:setPortionComplete(i - 1, #selectedPhotos)

            local shouldSkip = false
            if skipExisting then
                local existing = photo:getFormattedMetadata(metadataField)
                if existing and existing ~= "" then
                    shouldSkip = true
                end
            end

            if shouldSkip then
                skipped = skipped + 1
            else
                local photoName = photo:getFormattedMetadata('fileName')
                local success, err = generateAltTextForPhoto(photo, photoName, progressScope)
                if success then
                    successes = successes + 1
                else
                    failures = failures + 1
                    if err then
                        errors[err] = (errors[err] or 0) + 1
                    end
                end
            end

            progressScope:setPortionComplete(i, #selectedPhotos)
        end

        progressScope:done()

        if progressScope:isCanceled() then
            local parts = {"Operation canceled."}
            if successes > 0 then
                table.insert(parts, successes .. " photo(s) completed before cancellation.")
            end
            LrDialogs.message(table.concat(parts, " "))
        elseif failures == 0 and skipped == 0 then
            LrDialogs.showBezel("Alt text generated for " .. successes .. " photo(s).")
        else
            local parts = {}
            if successes > 0 then
                table.insert(parts, successes .. " succeeded")
            end
            if failures > 0 then
                table.insert(parts, failures .. " failed")
            end
            if skipped > 0 then
                table.insert(parts, skipped .. " skipped")
            end
            local summary = table.concat(parts, ", ") .. "."

            local errorDetails = {}
            for err, count in pairs(errors) do
                if count > 1 then
                    table.insert(errorDetails, err .. " (" .. count .. "x)")
                else
                    table.insert(errorDetails, err)
                end
            end
            if #errorDetails > 0 then
                summary = summary .. "\n\n" .. table.concat(errorDetails, "\n")
            end

            LrDialogs.message("Alt Text Generator", summary)
        end
    end)
end)
