module("L_VeraOpenSprinkler1", package.seeall)

local _PLUGIN_NAME = "VeraOpenSprinkler"
local _PLUGIN_VERSION = "1.4.5"

local debugMode = false
local masterID = -1
local openLuup = false

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
local SCHEMAS_DIMMER					= "urn:schemas-upnp-org:device:DimmableLight:1"
local SCHEMAS_HUMIDITY					= "urn:schemas-micasaverde-com:device:HumiditySensor:1"
local SCHEMAS_FREEZE					= "urn:schemas-micasaverde-com:device:FreezeSensor:1"

-- COMMANDS
local COMMANDS_STATUS					= "ja"
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

function httpGet(url)
	local timeout = 5
	local fileName = '/tmp/opensprinkler.json'

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

function httpGetOld(url)
	local ltn12 = require('ltn12')
	local http = require('socket.http')
	local https = require('ssl.https')

	local response, status, headers
	local response_body = {}

	-- Handler for HTTP or HTTPS?
	local requestor = url:lower():find("^https:") and https or http
	requestor.timeout = 5

	response, status, headers = requestor.request{
		method = "GET",
		url = url .. '&rnd=' .. tostring(math.random()),
		redirect = true,
		headers = {
			["Content-Type"] = "application/json; charset=utf-8",
			["Connection"] = "keep-alive"
		},
		sink = ltn12.sink.table(response_body)
	}

	D("HttpGet: %1 - %2 - %3 - %4", url, (response or ""), tostring(status), tostring(table.concat(response_body or "")))

	if status ~= nil and type(status) == "number" and tonumber(status) >= 200 and tonumber(status) < 300 then
		return true, table.concat(response_body or '')
	else
		return false, nil
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

	D("Cannot find child: %1 - %2", masterID, childID)
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
	local ip = luup.attr_get("ip", masterID) or ""

	local cmdUrl = string.format('http://%s/%s?%s&pw=%s', ip, cmd, pstr, password)
	D("sendDeviceCommand - url: %1", cmdUrl)
	if (ip ~= "") then return httpGet(cmdUrl) end

	return false, nil
end

local function discovery(jsonResponse)
	D("[discovery] in progress...")
	D("[discovery] valid jsonResponse: %1", jsonResponse ~= nil)
	if (jsonResponse == nil) then return end

	local childrenSameRoom = getVarNumeric(HASID, "ChildrenSameRoom", 1, masterID) == 1
	local roomID = tonumber(luup.attr_get("room", masterID))
	local child_devices = luup.chdev.start(masterID)
	D("ChildrenSameRoom: %1, #%2", childrenSameRoom, roomID)

	-- zones
	D("[discovery] 1/3 in progress...")
	if jsonResponse.stations and type(jsonResponse.stations.snames) == "table" then
	luup.log(jsonResponse.stations)
		local disabledStationsFlag = tonumber(jsonResponse.stations.stn_dis[1] or "0")

		-- get zones
		for zoneID, zoneName in ipairs(jsonResponse.stations.snames) do
			-- get disabled state
			local disabled = (disabledStationsFlag / math.pow(zoneID + 1, 2) ) % 2 >= 1
			
			D("Discovery: Zone %1 - Name: %2 - Disabled: %3", zoneID, zoneName, disabled)

			if not disabled then
				local childID = findChild(string.format(CHILDREN_ZONE, zoneID))

				-- Set the zone name
				-- TODO: if master valve, create as switch, not dimmer
				D("Zone Device ready to be added: %1", zoneID)
				local initialVariables = string.format("%s,%s=%s\n%s,%s=%s\n%s,%s=%s\n",
											MYSID, "ZoneID", (zoneID-1),
											"", "category_num", 2,
											"", "subcategory_num", 7
											)
				luup.chdev.append(masterID, child_devices, string.format(CHILDREN_ZONE, zoneID), zoneName, SCHEMAS_DIMMER, "D_DimmableLight1.xml", "", initialVariables, false)

				if childID ~= 0 then
					D("Set Name for Device %3 - Zone #%1: %2", zoneID, zoneName, childID)

					local overrideName = getVarNumeric(MYSID, "UpdateNameFromController", 1, childID) == 1
					local oldName =	luup.attr_get("name", childID)
					if overrideName and oldName ~= zoneName then
						luup.attr_set("name", zoneName, childID)
						setVar(MYSID, "UpdateNameFromController", 1, childID)
					end

					setVar(MYSID, "ZoneID", (zoneID-1), childID)

					if luup.attr_get("category_num", childID) == nil or tostring(luup.attr_get("subcategory_num", childID) or "0") ~= "2" then
						luup.attr_set("category_num", "2", childID)			-- Dimmer
						luup.attr_set("subcategory_num", "7", childID)		-- Water Valve
						setVar(HASID, "Configured", 1, childID)

						-- dimmers
						initVar(DIMMERSID, "LoadLevelTarget", "0", childID)
						initVar(DIMMERSID, "LoadLevelLast", "0", childID)
						initVar(DIMMERSID, "TurnOnBeforeDim", "0", childID)
						initVar(DIMMERSID, "AllowZeroLevel", "1", childID)
					end

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
	D("[discovery] 2/3 in progress...")
	local programs = jsonResponse.programs and tonumber(jsonResponse.programs.nprogs) or 0

	if programs > 0 then
		-- get programs
		for i = 1, programs do
			local programID = i-1

			--local counter = 0
			--for _, _ in ipairs(jsonResponse.programs.pd[i]) do counter = counter + 1 end
			local counter = table.getn(jsonResponse.programs.pd[i])
			local programName = jsonResponse.programs.pd[i][counter] -- last element in the array

			D("[discovery] Program %1 - Name: %2 - %3", programID, programName, jsonResponse.programs.pd[i])
	
			local childID = findChild(string.format(CHILDREN_PROGRAM, programID))

			-- Set the program name
			D("[discovery] Program Device ready to be added: %1", programID)

			local initialVariables = string.format("%s,%s=%s\n%s,%s=%s\n%s,%s=%s\n",
									MYSID, "ZoneID", (programID-1),
									"", "category_num", 3,
									"", "subcategory_num", 7
									)

			luup.chdev.append(masterID, child_devices, string.format(CHILDREN_PROGRAM, programID), programName, SCHEMAS_BINARYLIGHT, "D_BinaryLight1.xml", "", initialVariables, false)

			if childID ~= 0 then
				D("[discovery] Set Name for Device %3 - Program #%1: %2", programID, programName, childID)

				local overrideName = getVarNumeric(MYSID, "UpdateNameFromController", 1, childID) == 1
				local oldName =	luup.attr_get("name", childID)
				if overrideName and oldName ~= programName then
					luup.attr_set("name", programName, childID)
					setVar(MYSID, "UpdateNameFromController", 1, childID)
				end
				
				setVar(MYSID, "ProgramID", programID, childID)

				-- save program data, to stop stations when stopping the program
				local programData = jsonResponse.programs.pd[i][counter-1] -- last-1 element in the array
				if programData ~= nil then
					D("[discovery] Setting zone data: %1 - %2 - %3", childID, programID, programData)
					local programData_Zones = ""
					for i=1,#programData do
						programData_Zones = programData_Zones .. tostring(programData[i]) .. ","
					end
					setVar(MYSID, "Zones", programData_Zones, childID)
				else
					D("[discovery] Setting zone data FAILED: %1 - %2", childID, programID)
				end

				if luup.attr_get("category_num", childID) == nil or tostring(luup.attr_get("subcategory_num", childID) or "0") ~= "3" then
					luup.attr_set("category_num", "3", childID)			-- Switch
					luup.attr_set("subcategory_num", "7", childID)		-- Water Valve

					setVar(HASID, "Configured", 1, childID)
				end

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
	D("[discovery] 3/3 in progress...")

	local sensors =  {
		{id= "rs", name = "Rain Delay",		value = jsonResponse.settings.rd,	sensorType = 1, template = CHILDREN_SENSOR},
		{id= "s1", name = "Sensor 1",		value = jsonResponse.settings.sn1,	sensorType = tonumber(jsonResponse.options.sn1t or 0), template = CHILDREN_SENSOR},
		{id= "s2", name = "Sensor 2",		value = jsonResponse.settings.sn2,	sensorType = tonumber(jsonResponse.options.sn2t or 0), template = CHILDREN_SENSOR},
		{id= "0",  name = "Water Level",	value = jsonResponse.options.wl,	 sensorType = 666, template = CHILDREN_WATERLEVEL}
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
			D("[discovery] %s Child Device ready to be added", sensor.name)
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
			D("[discovery] %s Child Device ignored: %s", sensor.name, sensorType)
		end
	end

	D("[discovery] 3/3 completed...")

	luup.chdev.sync(masterID, child_devices)

	D("[discovery] completed...")
end

local function updateSensors(jsonResponse)
	local sensors =  {
		{id= "rs", name = "Rain Delay",		value = jsonResponse.settings.rd,	sensorType = 1, template = CHILDREN_SENSOR},
		{id= "s1", name = "Sensor 1",		value = jsonResponse.settings.sn1,	sensorType = tonumber(jsonResponse.options.sn1t or 0), template = CHILDREN_SENSOR},
		{id= "s2", name = "Sensor 2",		value = jsonResponse.settings.sn2,	sensorType = tonumber(jsonResponse.options.sn2t or 0), template = CHILDREN_SENSOR},
		{id= "0",  name = "Water Level",	value = jsonResponse.options.wl,	 sensorType = 666, template = CHILDREN_WATERLEVEL}
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
	D("Update status in progress...")

	-- STATUS
	local state = tonumber(jsonResponse and jsonResponse.settings and jsonResponse.settings.en or 0)
	D("Controller status: %1, %2", state, state == 1 and "1" or "0")
	setVar(SWITCHSID, "Status", state == 1 and "1" or "0", masterID)

	-- RAIN DELAY: if 0, disabled, otherwise raindelay stop time
	local rainDelay = tonumber(jsonResponse.settings.rdst)
	setVar(MYSID, "RainDelay", rainDelay, masterID)

	-- TODO: use local format and luup.timezone for time/date format
	local rainDelayDate = os.date("%H:%M:%S (%a %d %b %Y)", jsonResponse.settings.rdst)

	D("Update status - Status: %1 - RainDelay: %2 - %3", state, rainDelay, rainDelayDate)

	setVerboseDisplay(("Controller: " .. (state == 1 and "ready" or "disabled")),
					 ("RainDelay: " .. (rainDelay == 0 and "disabled" or ("enabled until " .. rainDelayDate))),
					 masterID)

	setLastUpdate(masterID)

	-- PROGRAM STATUS
	local programs = jsonResponse.settings.ps

	if programs ~= nil and #programs > 0 then
		for i = 2, #programs do -- ignore the program
			local programIndex = i-2
			local childID = findChild(string.format(CHILDREN_PROGRAM, programIndex))
			if childID > 0 then
				D("Program Status for %1: %2", childID, programs[i][1])
				local state = tonumber(programs[i][1] or "0") >= 1 and 1 or 0

				-- Check to see if program status changed
				local currentState = getVarNumeric(SWITCHSID, "Status", 0, childID)
				if currentState ~= state then
					initVar(SWITCHSID, "Target", "0", childID)
					setVar(HASID, "Configured", "1", childID)
					setVar(SWITCHSID, "Status", (state == 1) and "1" or "0", childID)

					setVerboseDisplay("Program: " .. ((state == 1) and "Running" or "Idle"), nil, childID)

					D("Update Program: %1 - Status: %2", iprogramIndex, state)
				else
					D("Update Program Skipped for #%1: %2 - Status: %3 - %4", childID, programIndex, state, currentState)
				end

				setLastUpdate(childID)
			end
		end
	else
		D("No programs defined, update skipped")
	end

	-- ZONE STATUS
	local stations = tonumber(jsonResponse.status.nstations) or 0

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
				D("Update Zone: %1 - Status: %2", i, state)
			else
				D("Update Zone Skipped for #%1: %2 - Status: %3 - %4", childID, i, state, currentState)
			end

			-- update level
			local ps = jsonResponse.settings.ps[i]
			D('Zone status: %1', ps)

			local level = math.floor(tonumber(ps[2]) / 60  + 0.5)
			setVar(DIMMERSID, "LoadLevelTarget", level, childID)
			setVar(DIMMERSID, "LoadLevelStatus", level, childID)
			D('Zone status level: %1', level)

			setLastUpdate(childID)
		else
			D("Zone not found: %1", i)
		end
	end

	-- SENSORS
	updateSensors(jsonResponse)
	
	-- MASTER STATIONS
	local masterStations = string.format("%s,%s", jsonResponse.options.mas, jsonResponse.options.mas2)
	setVar(MYSID, "MasterStations", masterStations, masterID)
end

function updateFromController()
	-- discovery only on first Running
	local configured = getVarNumeric(MYSID, "Configured", 0, masterID)
	local firstRun = configured == 0

	local _ ,json = pcall(require, "dkjson")

	-- check for dependencies
	if not json or type(json) ~= "table" then
		L('Failure: dkjson library not found')
		luup.set_failure( 1, devNum)
		return
	end

	D("updateFromController started: %1", firstRun)
	
	local status, response = sendDeviceCommand(COMMANDS_STATUS)
	if status and response ~= nil then
		local jsonResponse, _, err = json.decode(response)

		if err or jsonResponse == nil then
			D('Got a nil response from API or error: %1, %2', err, jsonResponse == nil)
		else
			if firstRun then
				discovery(jsonResponse)
				setVar(HASID, "Configured", 1, masterID)
			end

			updateStatus(jsonResponse)
		end
	else
		L("updateFromController error: %1", response)
	end
	
	D("updateFromController completed")

	-- schedule again
	local refresh = getVarNumeric(MYSID, "Refresh", 10, masterID)
	luup.call_delay("updateFromController", tonumber(refresh), false)

	D("Next refresh in " .. tostring(refresh) .. " secs")
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

	D("actionPower: %1 - %2", devNum, zoneIndex or programIndex or "-1")
	if sendCommand then
		local result, response = sendDeviceCommand(cmd, cmdParams)

		if result then
			setVar(SWITCHSID, "Status", state and "1" or "0", devNum)
		else
			deviceMessage(devNum, 'Unable to send command to controller', true)
			L("Switch power error: %1 - %2 - %3", devNum, state, response)
		end
	else
		D("actionPower: Command skipped")
	end

	deviceMessage(devNum, 'Turning ' .. (state and "on" or "off"), false)
end

function actionPowerStopStation(devNum)
	local v = getVar(MYSID, "Zones", ",", devNum)
	D("actionPowerStopStation: %1 - %2", devNum, v)
	local zones = split(v, ",")
	if zones ~= nil and #zones > 0 then
		for i=1,#zones-1 do -- ignore the last one
			if zones[i] ~= nil and tonumber(zones[i]) > 0 then -- if value > 0, then the zones is inside this program
				local childID = findChild(string.format(CHILDREN_ZONE, i))
				if childID > 0 then
					D("actionPowerStopStation: stop zone %1 - device %2", i, childID)
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

	-- detect OpenLuup
	openLuup = luup.openLuup ~= nil
	D("Running on OpenLuup: %1", openLuup)

	-- init
	initVar(SWITCHSID, "Target", "0", masterID)
	initVar(SWITCHSID, "Status", "-1", masterID)

	initVar(MYSID, "DebugMode", "0", masterID)

	initVar(MYSID, "Password", "a6d82bced638de3def1e9bbb4983225c", masterID) -- opendoor
	initVar(MYSID, "Refresh", "15", masterID)
	initVar(MYSID, "MaxZones", "32", masterID)

	-- categories
	if luup.attr_get("category_num", masterID) == nil or tostring(luup.attr_get("subcategory_num", masterID) or 0) == "0" then
		luup.attr_set("category_num", "3", masterID)			-- Switch
		luup.attr_set("subcategory_num", "7", masterID)			-- Water Valve
		luup.attr_set("device_file", "D_VeraOpenSprinkler1.xml", masterID) -- fix it at startup
	end

	-- IP configuration
	local ip = luup.attr_get("ip", masterID)
	if ip == nil or string.len(ip) == 0 then -- no IP = failure
		luup.set_failure(2, masterID)
		return false, "Please set controller IP adddress", _PLUGIN_NAME
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