------------------------------------------------------------------------
-- Copyright (c) 2020-2021 Daniele Bochicchio
-- License: MIT License
-- Source Code: https://github.com/dbochicchio/Vera-OpenSprinkler
------------------------------------------------------------------------

module("L_VeraOpenSprinkler1", package.seeall)

local _PLUGIN_NAME = "VeraOpenSprinkler"
local _PLUGIN_VERSION = "1.51-hotfix2"

local debugMode = false
local masterID = -1
local openLuup = false
local dateFormat = "yy-mm-dd"
local timeFormat = "24hr"

local taskHandle = -1
local TASK_ERROR = 2
local TASK_ERROR_PERM = -2
local TASK_SUCCESS = 4
local TASK_BUSY = 1

-- SIDS
local MYSID								= "urn:bochicchio-com:serviceId:OpenSprinkler1"
local SWITCHSID							= "urn:upnp-org:serviceId:SwitchPower1"
local DIMMERSID							= "urn:upnp-org:serviceId:Dimming1"
local HASID								= "urn:micasaverde-com:serviceId:HaDevice1"
local HUMIDITYSID						= "urn:micasaverde-com:serviceId:HumiditySensor1"
local SECURITYSID						= "urn:micasaverde-com:serviceId:SecuritySensor1"

local SCHEMAS_BINARYLIGHT				= "urn:schemas-upnp-org:device:BinaryLight:1"
local SCHEMAS_WATERVALVE				= "urn:schemas-micasaverde-com:device:WaterValve:1"
local SCHEMAS_DIMMER					= "urn:schemas-upnp-org:device:DimmableLight:1"
local SCHEMAS_HUMIDITY					= "urn:schemas-micasaverde-com:device:HumiditySensor:1"
local SCHEMAS_FREEZE					= "urn:schemas-micasaverde-com:device:FreezeSensor:1"

-- COMMANDS
local COMMANDS_STATUS					= "ja"
local COMMANDS_LEGACY_SETTINGS			= "jc"
local COMMANDS_LEGACY_OPTIONS			= "jo"
local COMMANDS_LEGACY_STATIONS			= "jn"
local COMMANDS_LEGACY_PROGRAMS			= "jp"
local COMMANDS_LEGACY_STATUS			= "js"
local COMMANDS_SETPOWER_ZONE			= "cm"
local COMMANDS_SETPOWER_PROGRAM			= "mp"
local COMMANDS_CHANGEVARIABLES			= "cv"

local CHILDREN_ZONE						= "OS-%s"
local CHILDREN_PROGRAM					= "OS-P-%s"
local CHILDREN_WATERLEVEL				= "OS-WL-%s"
local CHILDREN_SENSOR					= "OS-S-%s"

TASK_HANDLE = nil

--- ***** GENERIC FUNCTIONS *****
local function dump(t, seen)
	if t == nil then return "nil" end
	if seen == nil then seen = {} end
	local sep = ""
	local str = "{ "
	for k, v in pairs(t) do
		local val
		if type(v) == "table" then
			if seen[v] then
				val = "(recursion)"
			else
				seen[v] = true
				val = dump(v, seen)
			end
		elseif type(v) == "string" then
			if #v > 255 then
				val = string.format("%q", v:sub(1, 252) .. "...")
			else
				val = string.format("%q", v)
			end
		elseif type(v) == "number" and (math.abs(v - os.time()) <= 86400) then
			val = tostring(v) .. "(" .. os.date("%x.%X", v) .. ")"
		else
			val = tostring(v)
		end
		str = str .. sep .. k .. "=" .. val
		sep = ", "
	end
	str = str .. " }"
	return str
end

local function L(msg, ...) -- luacheck: ignore 212
	local str
	local level = 50
	if type(msg) == "table" then
		str = tostring(msg.prefix or (_PLUGIN_NAME .. "[" .. _PLUGIN_VERSION .. "]")) .. ": " .. tostring(msg.msg)
		level = msg.level or level
	else
		str = (_PLUGIN_NAME .. "[" .. _PLUGIN_VERSION .. "]") .. ": " .. tostring(msg)
	end
	str = string.gsub(str, "%%(%d+)", function(n)
		n = tonumber(n, 10)
		if n < 1 or n > #arg then return "nil" end
		local val = arg[n]
		if type(val) == "table" then
			return dump(val)
		elseif type(val) == "string" then
			return string.format("%q", val)
		elseif type(val) == "number" and math.abs(val - os.time()) <= 86400 then
			return tostring(val) .. "(" .. os.date("%x.%X", val) .. ")"
		end
		return tostring(val)
	end)
	luup.log(str, level)
end

local function getVarNumeric(sid, name, dflt, devNum)
	local s = luup.variable_get(sid, name, devNum) or ""
	if s == "" then return dflt end
	s = tonumber(s)
	return (s == nil) and dflt or s
end

local function D(msg, ...)
	debugMode = getVarNumeric(MYSID, "DebugMode", 0, masterID) == 1

	if debugMode then
		local t = debug.getinfo(2)
		local pfx = _PLUGIN_NAME .. "[" .. _PLUGIN_VERSION .. "]" ..  "(" .. tostring(t.name) .. "@" ..
						tostring(t.currentline) .. ")"
		L({msg = msg, prefix = pfx}, ...)
	end
end

local function setVar(sid, name, val, devNum)
	val = (val == nil) and "" or tostring(val)
	local s = luup.variable_get(sid, name, devNum) or ""
	D("setVar(%1,%2,%3,%4) old value %5", sid, name, val, devNum, s)
	if s ~= val then
		luup.variable_set(sid, name, val, devNum)
		return true, s
	end
	return false, s
end

local function getVar(sid, name, dflt, devNum)
	local s = luup.variable_get(sid, name, devNum) or ""
	if s == "" then return dflt end
	return (s == nil) and dflt or s
end

local function split(str, sep)
	if sep == nil then sep = "," end
	local arr = {}
	if #(str or "") == 0 then return arr, 0 end
	local rest = string.gsub(str or "", "([^" .. sep .. "]*)" .. sep,
		function(m)
			table.insert(arr, m)
			return ""
		end)
	table.insert(arr, rest)
	return arr, #arr
end

local function map(arr, f, res)
	res = res or {}
	for ix, x in ipairs(arr) do
		if f then
			local k, v = f(x, ix)
			res[k] = (v == nil) and x or v
		else
			res[x] = x
		end
	end
	return res
end

local function initVar(sid, name, dflt, devNum)
	local currVal = luup.variable_get(sid, name, devNum)
	if currVal == nil then
		luup.variable_set(sid, name, tostring(dflt), devNum)
		return tostring(dflt)
	end
	return currVal
end

local function formatDateTime(v)
	return string.format("%s %s",
		os.date(dateFormat:gsub("yy", "%%Y"):gsub("mm", "%%m"):gsub("dd", "%%d"), v),
		os.date(timeFormat == "12hr" and "%I:%M:%S%p" or "%H:%M:%S", v)
		)
end

function httpGet(url)
	-- purge files after 2 minutes
	os.execute("find /tmp/opensprinkler_*.json ! -mtime 2 | xargs rm -rf")

	local timeout = 5
	local fileName = "/tmp/opensprinkler_" .. tostring(math.random(0, 999999)) .. ".json"

	local httpCmd = string.format("curl -m %d -o '%s' -k -L -H 'Content-type: application/json' '%s'",
								timeout,
								fileName,
								url)

	local res, err = os.execute(httpCmd)
	if res ~= 0 then
		D("[HttpGet] CURL failed: %1 %2: %3", res, err, httpCmd)
		return false, nil
	else
		local file, err = io.open(fileName, "r")
		if not file then
			D("[HttpGet] Cannot read response file: %1 - %2", fileName, err)
			return false, nil
		end

		local response_body = file:read('*all')
		file:close()

		D("[HttpGet] %1 - %2", url, (response_body or ""))

		return true, response_body
	end
end

local function setLastUpdate(devNum)
	luup.variable_set(HASID, "LastUpdate", os.time(), devNum)
	luup.set_failure(0, devNum)
end

local function setVerboseDisplay(line1, line2, devNum)
	if line1 then setVar(MYSID, "DisplayLine1", line1 or "", devNum) end
	if line2 then setVar(MYSID, "DisplayLine2", line2 or "", devNum) end
end

local function findChild(childID)
	for k, v in pairs(luup.devices) do
		if tonumber(v.device_num_parent) == masterID and v.id == childID then
			return k
		end
	end

	D("[findChild] Not found %2 for master #%1", masterID, childID)
	return 0
end

function deviceMessage(devNum, message, error, timeout)
	local status = error and 2 or 4
	timeout = timeout or 15
	D("deviceMessage(%1,%2,%3,%4)", devNum, message, error, timeout)
	luup.device_message(devNum, status, message, timeout, _PLUGIN_NAME)
end

function clearMessage()
	deviceMessage(masterID, "Clearing...", TASK_SUCCESS, 0)
end

--- ***** CUSTOM FUNCTIONS *****
local function sendDeviceCommand(cmd, params)
	D("sendDeviceCommand(%1,%2,%3)", cmd, params, masterID)
	
	local pv = {}
	if type(params) == "table" then
		for k, v in ipairs(params) do
			if type(v) == "string" then
				pv[k] = v -- string.format( "%q", v )
			else
				pv[k] = tostring(v)
			end
		end
	elseif type(params) == "string" then
		table.insert(pv, params)
	elseif params ~= nil then
		table.insert(pv, tostring(params))
	end
	local pstr = table.concat(pv, "&") or ""

	local password = getVar(MYSID, "Password", "", masterID)
	local ip = getVar(MYSID, "IP", "", masterID)

	local cmdUrl = string.format('http://%s/%s?%s&pw=%s', ip, cmd, pstr, password)
	D("sendDeviceCommand - url: %1", cmdUrl)
	if (ip ~= "") then return httpGet(cmdUrl) end

	return false, nil
end

local function discovery(jsonResponse)
	L("[discovery] in progress... - valid jsonResponse: %1", jsonResponse ~= nil)
	if (jsonResponse == nil) then return end

	local childrenSameRoom = getVarNumeric(HASID, "ChildrenSameRoom", 1, masterID) == 1
	local roomID = tonumber(luup.attr_get("room", masterID))
	local child_devices = luup.chdev.start(masterID)
	D("[discovery] ChildrenSameRoom: %1, #%2", childrenSameRoom, roomID)

	-- zones
	L("[discovery] 1/3 in progress...")
	if jsonResponse.stations and type(jsonResponse.stations.snames) == "table" then
		local disabledStationsFlag = tonumber(jsonResponse.stations.stn_dis[1] or "0")

		-- get zones
		for zoneID, zoneName in ipairs(jsonResponse.stations.snames) do
			-- get disabled state
			local disabled = (disabledStationsFlag / math.pow(zoneID + 1, 2) ) % 2 >= 1
			
			D("[discovery] Zone %1 - Name: %2 - Disabled: %3", zoneID, zoneName, disabled)

			if not disabled then
				local childID = findChild(string.format(CHILDREN_ZONE, zoneID))

				-- Set the zone name
				-- TODO: if master valve, create as switch, not dimmer
				D("[discovery] Adding zone: %1 - #%2", zoneID, childID)
				local initialVariables = string.format("%s,%s=%s\n%s,%s=%s\n%s,%s=%s\n",
											MYSID, "ZoneID", (zoneID-1),
											"", "room", roomID,
											"", "category_num", 3,
											"", "subcategory_num", 7
											)
				luup.chdev.append(masterID, child_devices, string.format(CHILDREN_ZONE, zoneID), zoneName, SCHEMAS_DIMMER, "D_VeraOpenSprinklerStation1.xml", "", initialVariables, false)

				if childID ~= 0 then
					D("[discovery] Updating Zone #%1 - %2: %3", childID, zoneID, zoneName)

					local overrideName = getVarNumeric(MYSID, "UpdateNameFromController", 1, childID) == 1
					local oldName =	luup.attr_get("name", childID)
					if overrideName and oldName ~= zoneName then
						luup.attr_set("name", zoneName, childID)
						setVar(MYSID, "UpdateNameFromController", 1, childID)
					end

					setVar(MYSID, "ZoneID", (zoneID-1), childID)

					-- fix device types
					luup.attr_set("device_file", "D_VeraOpenSprinklerStation1.xml", childID)
					luup.attr_set("device_json", "D_VeraOpenSprinklerStation1.json", childID)

					luup.attr_set("category_num", "3", childID)			-- Dimmer
					luup.attr_set("subcategory_num", "7", childID)		-- Water Valve
					setVar(HASID, "Configured", 1, childID)

					-- dimmer
					initVar(DIMMERSID, "LoadLevelTarget", "0", childID)
					initVar(DIMMERSID, "LoadLevelLast", "0", childID)
					initVar(DIMMERSID, "TurnOnBeforeDim", "0", childID)
					initVar(DIMMERSID, "AllowZeroLevel", "1", childID)

					-- switch
					initVar(SWITCHSID, "Target", "0", childID)
					initVar(SWITCHSID, "Status", "0", childID)

					if childrenSameRoom then
						luup.attr_set("room", roomID, childID)
					end

					setLastUpdate(childID)
				end
			end
		end
	else
		L("[discovery] 1/3: nil response from controller")
	end

	D("[discovery] 1/3 completed...")

	-- programs
	L("[discovery] 2/3 in progress...")
	local programs = jsonResponse.programs and tonumber(jsonResponse.programs.nprogs) or 0

	D("[discovery] 2/3 Programs: %1", programs)
	if programs > 0 then
		-- get programs
		for programID = 1, programs do
			local counter = table.getn(jsonResponse.programs.pd[programID])
			local programName = jsonResponse.programs.pd[programID][counter] -- last element in the array

			D("[discovery] Program %1 - Name: %2 - %3", programID, programName, jsonResponse.programs.pd[programID])
	
			local childID = findChild(string.format(CHILDREN_PROGRAM, programID))

			-- Set the program name
			D("[discovery] Adding program: %1 - #%2", programID, childID)

			-- save program data, to stop stations when stopping the program
			local programData = jsonResponse.programs.pd[programID][counter-1] -- last-1 element in the array
			local programData_Zones = ""
			D("[discovery] Setting zone data: %1 - %2 - %3", childID, programID, programData)
			if programData ~= nil then
				for i=1,#programData do
					programData_Zones = programData_Zones .. tostring(programData[programID]) .. ","
				end
			end

			local initialVariables = string.format("%s,%s=%s\n%s,%s=%s\n%s,%s=%s\n",
									MYSID, "ProgramID", (programID-1),
									MYSID, "Zones", (programData_Zones or ""),
									"", "room", roomID,
									"", "category_num", 3,
									"", "subcategory_num", 7
									)

			luup.chdev.append(masterID, child_devices, string.format(CHILDREN_PROGRAM, programID), programName, SCHEMAS_BINARYLIGHT, "D_VeraOpenSprinkler1.xml", "", initialVariables, false)

			if childID ~= 0 then
				D("[discovery] Updating Program %1 - Name: %2 - %3", programID, programName, childID)

				local overrideName = getVarNumeric(MYSID, "UpdateNameFromController", 1, childID) == 1
				local oldName =	luup.attr_get("name", childID)
				if overrideName and oldName ~= programName then
					luup.attr_set("name", programName, childID)
					setVar(MYSID, "UpdateNameFromController", 1, childID)
				end
				
				setVar(MYSID, "ProgramID", (programID -1), childID)

				-- save program data, to stop stations when stopping the program
				if programData_Zones ~= nil then
					setVar(MYSID, "Zones", programData_Zones, childID)
				else
					D("[discovery] Setting zone data FAILED: %1 - %2", childID, programID)
				end

				-- fix device types
				luup.attr_set("device_file", "D_VeraOpenSprinkler1.xml", childID)
				luup.attr_set("device_json", "D_WaterValve1.json", childID)

				luup.attr_set("category_num", "3", childID)			-- Switch
				luup.attr_set("subcategory_num", "7", childID)		-- Water Valve
				setVar(HASID, "Configured", 1, childID)
				
				-- switch
				initVar(SWITCHSID, "Target", "0", childID)
				initVar(SWITCHSID, "Status", "0", childID)

				if childrenSameRoom then
					luup.attr_set("room", roomID, childID)
				end

				setLastUpdate(childID)
			end
		end
	else
		L("[discovery] 2/3: no programs from controller")
	end

	D("[discovery] 2/3 completed...")

	-- SENSORS
	L("[discovery] 3/3 in progress...")

	if jsonResponse.settings ~= nil and jsonResponse.options ~= nil then
		local sensors =  {
			{id= "rs", name = "Rain Delay",		value = jsonResponse.settings.rd,	sensorType = 1, template = CHILDREN_SENSOR},
			{id= "s1", name = "Sensor 1",		value = jsonResponse.settings.sn1,	sensorType = tonumber(jsonResponse.options.sn1t or 0), template = CHILDREN_SENSOR},
			{id= "s2", name = "Sensor 2",		value = jsonResponse.settings.sn2,	sensorType = tonumber(jsonResponse.options.sn2t or 0), template = CHILDREN_SENSOR},
			{id= "0",  name = "Water Level",	value = jsonResponse.options.wl,	sensorType = 666, template = CHILDREN_WATERLEVEL}
		}

		for _, sensor in ipairs(sensors) do
			if sensor.sensorType > 0 then
				local childID = findChild(string.format(sensor.template, sensor.id))
	
				-- category 4, 7: Freeze Sensor
				-- category 33 Flow Meter

				local categoryNum = 4
				local subCategoryNum = 7
				local deviceXml =  "D_FreezeSensor1.xml"
				local deviceSchema = SCHEMAS_FREEZE

				-- water level as HumiditySensor
				if sensor.sensorType == 666  then
					categoryNum = 16
					subCategoryNum = 0
					deviceXml =  "D_HumiditySensor1.xml"
					deviceSchema = SCHEMAS_HUMIDITY
				end

				-- Set the program names
				D("[discovery] Adding device %1 - #%2", sensor.name, childID)
				local initialVariables = string.format("%s,%s=%s\n%s,%s=%s\n",
												"", "category_num", categoryNum,
												"", "subcategory_num", subCategoryNum
												)

				luup.chdev.append(masterID, child_devices, string.format(sensor.template, sensor.id), sensor.name, deviceSchema, deviceXml, "", initialVariables, false)

				if childID ~= 0 then
					if luup.attr_get("category_num", childID) == nil then
						luup.attr_set("category_num", categoryNum, childID)
						luup.attr_set("subcategory_num", subCategoryNum, childID)

						setVar(HASID, "Configured", 1, childID)
					end

					if childrenSameRoom then
						luup.attr_set("room", roomID, childID)
					end

					setLastUpdate(childID)
				end
			else
				D("[discovery] Child Device (%1) ignored: %2", sensor.name, sensorType)
			end
		end
	end

	D("[discovery] 3/3 completed...")

	luup.chdev.sync(masterID, child_devices)

	L("[discovery] completed - children sync'ed...")
end

local function updateSensors(jsonResponse)
	if jsonResponse.settings == nil or jsonResponse.options == nil then
		return false
	end

	local sensors =  {
		{id= "rs", name = "Rain Delay",		value = jsonResponse.settings.rd,	sensorType = 1, template = CHILDREN_SENSOR},
		{id= "s1", name = "Sensor 1",		value = jsonResponse.settings.sn1,	sensorType = tonumber(jsonResponse.options.sn1t or 0), template = CHILDREN_SENSOR},
		{id= "s2", name = "Sensor 2",		value = jsonResponse.settings.sn2,	sensorType = tonumber(jsonResponse.options.sn2t or 0), template = CHILDREN_SENSOR},
		{id= "0",  name = "Water Level",	value = jsonResponse.options.wl,	sensorType = 666, template = CHILDREN_WATERLEVEL}
	}

	for _, sensor in ipairs(sensors) do
		local rainDelaySensor = sensor.value or 0
		local childID = findChild(string.format(sensor.template, sensor.id))
		if childID > 0 then
			if sensor.sensorType == 666 then
				setVar(HUMIDITYSID, "CurrentLevel", sensor.value or 0, childID)
				D("Setting Water level: %1 to dev#: %2", sensor.value or 0, childID)
			else
				setVar(SECURITYSID, "Tripped", sensor.value or 0, childID)
				D("Sensor Status for %1: %2", childID, sensor.value or "")
			end

			setLastUpdate(childID)
		end
	end

--	- sn1t: Sensor 1 type. (0: not using sensor; 1: rain sensor; 2: flow sensor; 3: soil sensor; 240 (i.e. 0xF0): program switch).
--	- sn1o: Sensor 1 option. (0: normally closed; 1: normally open). Default is normally open. (note the previous urs and rso options are replaced by sn1t and sn1o)
--	- sn1on/sn1of: Sensor 1 delayed on time and delayed off time (unit is minutes).
--	- sn2t/sn2o: Sensor 2 type and sensor 2 option (similar to sn1t and sn1o, for OS 3.0 only).
--	- sn2on/sn2of: Sensor 2 delayed on time and delayed off time (unit is minutes).
end

local function updateStatus(jsonResponse)
	D("[updateStatus] in progress...")

	if jsonResponse == nil then
		D("[updateStatus]: nil response")
		return
	end

	-- STATUS
	local state = tonumber(jsonResponse and jsonResponse.settings and jsonResponse.settings.en or 0)
	D("[updateStatus] Controller status: %1, %2", state, state == 1 and "1" or "0")
	setVar(SWITCHSID, "Status", state == 1 and "1" or "0", masterID)

	-- RAIN DELAY: if 0, disabled, otherwise raindelay stop time
	local rainDelay = tonumber(jsonResponse.settings.rdst)
	setVar(MYSID, "RainDelay", rainDelay, masterID)
	local rainDelayDate = formatDateTime(jsonResponse.settings.rdst)

	D("[updateStatus] Status: %1 - RainDelay: %2 - %3", state, rainDelay, rainDelayDate)

	setVerboseDisplay(("Controller: " .. (state == 1 and "ready" or "disabled")),
					 ("RainDelay: " .. (rainDelay == 0 and "disabled" or ("enabled until " .. rainDelayDate))),
					 masterID)

	setLastUpdate(masterID)

	-- PROGRAM STATUS
	local programs = jsonResponse.settings.ps

	if programs ~= nil and #programs > 0 then
		for i = 2, #programs do -- ignore the program
			local programIndex = i-1
			local childID = findChild(string.format(CHILDREN_PROGRAM, programIndex))
			if childID > 0 then
				D("[updateStatus] Program Status for %1: %2", childID, programs[i][1])
				local state = tonumber(programs[i][1] or "0") >= 1 and 1 or 0

				-- Check to see if program status changed
				local currentState = getVarNumeric(SWITCHSID, "Status", 0, childID)
				if currentState ~= state then
					initVar(SWITCHSID, "Target", "0", childID)
					setVar(HASID, "Configured", "1", childID)
					setVar(SWITCHSID, "Status", (state == 1) and "1" or "0", childID)

					setVerboseDisplay("Program: " .. ((state == 1) and "Running" or "Idle"), nil, childID)

					D("[updateStatus] Program: %1 - Status: %2", iprogramIndex, state)
				else
					D("[updateStatus] Program Skipped for #%1: %2 - Status: %3 - %4", childID, programIndex, state, currentState)
				end

				setLastUpdate(childID)
			end
		end
	else
		D("[updateStatus] No programs defined, update skipped")
	end

	-- ZONE STATUS
	if jsonResponse.status ~= nil then
		local stations = tonumber(jsonResponse.status.nstations or 8)
		setVar(MYSID, "MaxZones", stations, masterID)
		
		for i = 1, stations do
			-- Locate the device which represents the irrigation zone
			local childID = findChild(string.format(CHILDREN_ZONE, i))

			if childID > 0 then
				local state = tonumber(jsonResponse.status.sn[i] or "0")

				-- update zone status if changed
				local currentState = getVarNumeric(SWITCHSID, "Status", 0, childID)
				if currentState ~= state then
					initVar(SWITCHSID, "Target", "0", childID)
					setVar(HASID, "Configured", "1", childID)

					setVar(SWITCHSID, "Status", (state == 1) and "1" or "0", childID)

					setVerboseDisplay("Zone: " .. ((state == 1) and "Running" or "Idle"), nil, childID)
					D("[updateStatus] Zone: %1 - Status: %2", i, state)
				else
					D("[updateStatus] Zone Update Skipped for #%1: %2 - Status: %3 - %4", childID, i, state, currentState)
				end

				-- update level
				local ps = jsonResponse.settings.ps[i]
				D('[updateStatus] Zone: %1', ps)

				local level = math.floor(tonumber(ps[2]) / 60  + 0.5)

				if level == 0 and state == 1 then
					D('[updateStatus] Zone %1 Level adjusted to 1', ps)
					level = 1
				end

				--setVar(DIMMERSID, "LoadLevelTarget", level, childID)
				setVar(DIMMERSID, "LoadLevelStatus", level, childID)
				D('[updateStatus] Zone level: %1', level)

				setLastUpdate(childID)
			else
				D("[updateStatus] Zone not found: %1", i)
			end
		end
	end

	-- SENSORS
	updateSensors(jsonResponse)
	
	-- MASTER STATIONS
	if jsonResponse.options ~= nil then
		local masterStations = string.format("%s,%s", jsonResponse.options.mas, jsonResponse.options.mas2)
		setVar(MYSID, "MasterStations", masterStations, masterID)
	end
end

function updateFromControllerLegacy()
	local _ ,json = pcall(require, "dkjson")

	local _, settings = sendDeviceCommand(COMMANDS_LEGACY_SETTINGS)
	local _, programs = sendDeviceCommand(COMMANDS_LEGACY_PROGRAMS)
	local _, stations = sendDeviceCommand(COMMANDS_LEGACY_STATIONS)
	local _, options = sendDeviceCommand(COMMANDS_LEGACY_OPTIONS)
	local _, status = sendDeviceCommand(COMMANDS_LEGACY_STATUS)

	local response = {
		settings = json.decode(settings),
		stations = json.decode(stations),
		programs = json.decode(programs),
		options = json.decode(options),
		status =  json.decode(status)
	}
	D("updateFromControllerLegacy: %1", response)

	return true, "", response
end

function updateFromController(force)
	force = tostring(force or false) == "true"

	-- discovery only on first run
	local configured = getVarNumeric(HASID, "Configured", 0, masterID)
	-- suppor for legay mode - 1.4.6+
	local legacyMode = getVarNumeric(MYSID, "LegacyMode", 0, masterID)
	D("[updateFromController] Configured: %1 - Legacy mode: %2 - Forced: %3", configured, legacyMode, force)

	local _ ,json = pcall(require, "dkjson")

	-- check for dependencies
	if not json or type(json) ~= "table" then
		L('Failure: dkjson library not found')
		luup.set_failure( 1, devNum)
		return
	end

	local status, response, jsonResponse = false, nil, nil
	if legacyMode == 1 then
		status, _, jsonResponse = updateFromControllerLegacy()
	else
		status, response = sendDeviceCommand(COMMANDS_STATUS)
	end

	if status and (response ~= nil or jsonResponse ~=nil) then
		if jsonResponse == nil then
			jsonResponse, _, err = json.decode(response)
		end

		if err or jsonResponse == nil then
			D('[updateFromController] nil response or error: %1, %2', err, jsonResponse == nil)
		else
			if configured == 0 or force then
				discovery(jsonResponse)
				setVar(HASID, "Configured", 1, masterID)
			end

			updateStatus(jsonResponse)
		end
	else
		L("[updateFromController] error: %1 - %2 - %3", status, response, jsonResponse)
	end
	
	D("[updateFromController] completed")

	-- schedule again
	local refresh = getVarNumeric(MYSID, "Refresh", 10, masterID)
	luup.call_delay("updateFromController", tonumber(refresh), false)

	D("[updateFromController] Next refresh in " .. tostring(refresh) .. " secs")
end

function actionPower(state, devNum)
	-- Switch on/off
	if type(state) == "string" then
		state = (tonumber(state) or 0) ~= 0
	elseif type(state) == "number" then
		state = state ~= 0
	end

	local level = getVarNumeric(DIMMERSID, "LoadLevelLast", 5, devNum) -- in minutes

	actionPowerInternal(state, level * 60, devNum) -- in seconds
end

function actionDimming(level, devNum)
	if (devNum == masterID) then return end -- no dimming on master

	level = tonumber(level or "0")

	if (level <=0) then
		level = 0
	elseif (level>=100) then
		level = 100
	end
	local state = level > 0

	D("actionDimming: %1, %2, %3", devNum, level, state)

	setVar(DIMMERSID, "LoadLevelTarget", level, devNum)
	setVar(DIMMERSID, "LoadLevelLast", level, devNum)
	setVar(DIMMERSID, "LoadLevelStatus", level, devNum)

	actionPowerInternal(state, level * 60, devNum)
end

function actionPowerInternal(state, seconds, devNum)
	setVar(SWITCHSID, "Target", state and "1" or "0", devNum)

	local sendCommand = true

	-- master or zone?
	local cmd = COMMANDS_SETPOWER_ZONE
	local zoneIndex = getVarNumeric(MYSID, "ZoneID", -1, devNum)
	local programIndex = getVarNumeric(MYSID, "ProgramID", -1, devNum)

	local isMaster = devNum == masterID
	local isZone = zoneIndex > -1
	local isProgram = programIndex > -1

	local cmdParams = {
				"en=" .. tostring(state and "1" or "0"),	-- enable flag
				"t=" .. tostring(seconds),					-- timeout, for programs only
				"sid=" .. tostring(zoneIndex),				-- station id, for stations
				"pid=" .. tostring(programIndex),			-- program id, for programs
				"uwt=0"										-- use weather adjustment
				}

	if isMaster then
		cmd = COMMANDS_CHANGEVARIABLES
		cmdParams = {
				"en=" .. tostring(state and "1" or "0"),	-- enable flag
				}
	elseif isProgram then
		cmd = COMMANDS_SETPOWER_PROGRAM
		if not state then
			sendCommand = false

			actionPowerStopStation(devNum)

			setVar(SWITCHSID, "Status", "0", devNum) -- stop it in the UI
		end
	end

	D("[actionPower] #%1 - %2", devNum, zoneIndex or programIndex or "-1")
	if sendCommand then
		local result, response = sendDeviceCommand(cmd, cmdParams)

		if result then
			setVar(SWITCHSID, "Status", state and "1" or "0", devNum)
		else
			deviceMessage(devNum, 'Unable to send command to controller', true)
			L("[actionPower] Switch power error: %1 - %2 - %3", devNum, state, response)
		end
	else
		D("[actionPower] Command skipped")
	end

	deviceMessage(devNum, 'Turning ' .. (state and string.format("on for %s seconds", seconds) or "off"), false)
end

function actionPowerStopStation(devNum)
	local v = getVar(MYSID, "Zones", ",", devNum)
	D("[actionPowerStopStation] %1 - %2", devNum, v)
	local zones = split(v, ",")
	if zones ~= nil and #zones > 0 then
		for i=1,#zones-1 do -- ignore the last one
			if zones[i] ~= nil and tonumber(zones[i]) > 0 then -- if value > 0, then the zones is inside this program
				local childID = findChild(string.format(CHILDREN_ZONE, i))
				if childID > 0 then
					D("[actionPowerStopStation] stop zone %1 - device %2", i, childID)
					actionPowerInternal(false, 0, childID)
				end
			end
		end
	end
end

function actionSetRainDelay(newVal, devNum)
	D("actionSetRainDelay(%1,%2)", newVal, devNum)

	sendDeviceCommand(COMMANDS_CHANGEVARIABLES, {"rd=" .. tostring(newVal)}, devNum)
	setVar(MYSID, "RainDelay", 1, devNum)
end

function actionToggleState(devNum)
	local currentState = getVarNumeric(SWITCHSID, "Status", 0, devNum) == 1
	actionPower(not currentState, devNum)
end

function startPlugin(devNum)
	masterID = devNum

	L("Plugin starting: %1 - %2", _PLUGIN_NAME, _PLUGIN_VERSION)

	-- date format support
	dateFormat = luup.attr_get("date_format", 0) or "yy-mm-dd"
	timeFormat = luup.attr_get("timeFormat", 0) or "24hr"

	-- detect OpenLuup
	for k,v in pairs(luup.devices) do
		if v.device_type == "openLuup" then
			openLuup = true
		end
	end
	D("[startup] OpenLuup: %1", openLuup)

	-- init
	initVar(SWITCHSID, "Target", "0", masterID)
	initVar(SWITCHSID, "Status", "0", masterID)

	initVar(MYSID, "DebugMode", "0", masterID)
	initVar(MYSID, "LegacyMode", "0", masterID)

	initVar(MYSID, "Password", "a6d82bced638de3def1e9bbb4983225c", masterID) -- opendoor
	initVar(MYSID, "Refresh", "15", masterID)
	initVar(MYSID, "MaxZones", "32", masterID)

	-- categories
	if luup.attr_get("category_num", masterID) == nil or tostring(luup.attr_get("subcategory_num", masterID) or 0) == "0" or luup.attr_get("device_json") ~= "D_WaterValve1.json" then
		luup.attr_set("category_num", "3", masterID)						-- Switch
		luup.attr_set("subcategory_num", "7", masterID)						-- Water Valve
		luup.attr_set("device_file", "D_VeraOpenSprinkler1.xml", masterID)	-- fix it at startup
		luup.attr_set("device_json", "D_WaterValve1.json", masterID)		-- fix it at startup
	end

	-- IP configuration
	local ip = luup.attr_get("ip", masterID)
	if ip ~= nil and ip ~= "" then
		initVar(MYSID, "IP", ip, masterID)
		luup.attr_set("ip", "", masterID)
		D("[startup] IP migrated")
	else
		ip = getVar(MYSID, "IP", "", masterID)
		D("[startup] IP loaded: %1", ip)
	end

	if ip == nil or string.len(ip) == 0 then -- no IP = failure
		luup.set_failure(2, masterID)
		return false, "Please set controller's IP adddress", _PLUGIN_NAME
	end

	math.randomseed(tonumber(tostring(os.time()):reverse():sub(1,6)))

	-- currentversion
	local vers = initVar(MYSID, "CurrentVersion", "0", masterID)
	if vers ~= _PLUGIN_VERSION then
		-- new version, let's reload the script again
		L("New version detected: reconfiguration in progress")
		setVar(HASID, "Configured", 0, masterID)
		setVar(MYSID, "CurrentVersion", _PLUGIN_VERSION, masterID)
	end

	initVar(HASID, "ChildrenSameRoom", "1", masterID)

	-- startupDeferred
	local refresh = getVarNumeric(MYSID, "Refresh", 10, masterID)
	luup.call_delay("updateFromController", tonumber(refresh), false)

	-- status
	luup.set_failure(0, masterID)
	return true, "Ready", _PLUGIN_NAME
end