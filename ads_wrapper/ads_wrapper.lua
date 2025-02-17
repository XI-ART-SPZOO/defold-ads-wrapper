local mediator = require("ads_wrapper.mediator")
local queue = require("ads_wrapper.queue")
local wrapper = require("ads_wrapper.wrapper")
local helper = require("ads_wrapper.ads_networks.helper")

local M = {}

-- constants
M.T_REWARDED = hash("T_REWARDED")
M.T_INTERSTITIAL = hash("T_INTERSTITIAL")
M.T_BANNER = hash("T_BANNER")

local BANNER = "Banner"
local VIDEO = "Video"
-- constants

M.is_debug = sys.get_engine_info().is_debug

---@type ads_mediator
local video_mediator = nil
---@type ads_mediator
local banner_mediator = nil
---@type table<integer, ads_network>
local networks = {}

local queues = {}
local initialized = false
local banner_auto_hide = false
local banner_hidden = true

---Handler for error when mediator isn't setup
---@param name string mediator name
---@param callback ads_callback|nil
local function mediator_error(name, callback)
    if callback then
        timer.delay(0, false, function()
            callback(helper.error(name .. " mediator not setup"))
        end)
    end
end

---Call callback in the second frame.
---It is necessary to use timer for the coroutine to continue.
---@param callback ads_callback|nil
---@param result ads_response
local function handle(callback, result)
    if callback then
        timer.delay(0, false, function()
            callback(result)
        end)
    end
end

---Checks for internet connection
---@return boolean
function M.is_internet_connected()
    return sys.get_connectivity() ~= sys.NETWORK_DISCONNECTED
end

---Creates queue for initialization
---@return ads_queue
local function create_init()
    local q = queue.create()
    queue.add(q, wrapper.check_connection)
    queue.add(q, wrapper.request_idfa)
    queue.add(q, wrapper.init)
    return q
end

---Creates queue for load_interstitial function
---@return ads_queue
local function create_load_interstitial()
    local q = create_init()
    queue.add(q, wrapper.load_interstitial)
    return q
end

---Creates queue for show_interstitial function
---@return ads_queue
local function create_show_interstitial()
    local q = create_load_interstitial()
    queue.add(q, wrapper.show_interstitial)
    return q
end

---Creates queue for load_rewarded function
---@return ads_queue
local function create_load_rewarded()
    local q = create_init()
    queue.add(q, wrapper.load_rewarded)
    return q
end

---Creates queue for show_rewarded function
---@return ads_queue
local function create_show_rewarded()
    local q = create_load_rewarded()
    queue.add(q, wrapper.show_rewarded)
    return q
end

---Creates queue for load_banner function
---@return ads_queue
local function create_load_banner()
    local q = create_init()
    queue.add(q, wrapper.load_banner)
    return q
end

---Creates queue for show_banner function
---@return ads_queue
local function create_show_banner()
    local q = queue.create()
    queue.add(q, wrapper.check_connection)
    queue.add(q, wrapper.is_banner_showed)
    queue.add(q, wrapper.request_idfa)
    queue.add(q, wrapper.init)
    queue.add(q, wrapper.load_banner)
    queue.add(q, wrapper.show_banner)
    return q
end

---Creates queue for unload_banner function
---@return ads_queue
local function create_unload_banner()
    local q = queue.create()
    queue.add(q, wrapper.unload_banner)
    return q
end

---Creates queue for hide_banner function
---@return ads_queue
local function create_hide_banner()
    local q = queue.create()
    queue.add(q, wrapper.hide_banner)
    return q
end

---Remove all registered networks
function M.clear_networks()
    networks = {}
    ---@diagnostic disable-next-line: cast-local-type
    video_mediator = nil
    ---@diagnostic disable-next-line: cast-local-type
    banner_mediator = nil
end

---Registers network. Returns id
---@param network ads_network
---@param params any|nil parameters to be passed to the network.setup function
---@return integer|nil
function M.register_network(network, params)
    if network.is_supported() then
        local id = #networks + 1
        networks[id] = network
        network.setup(params)
        return id
    else
        pprint(network.NAME .. " Network is not supported for this platform. Network not registered")
        return nil
    end
end

---Setups interstitial and reward mediator
---@param order ads_order[]
---@param repeat_count number|nil Specified if after the first cycle in queue it is necessary to cut off a part of the order. Default: the total number of all networks.
function M.setup_video(order, repeat_count)
    video_mediator = mediator.create_mediator()
    mediator.setup(video_mediator, networks, order, repeat_count)
end

---Setups banner mediator
---@param order ads_order[]
---@param repeat_count number|nil Specified if after the first cycle in queue it is necessary to cut off a part of the order. Default: the total number of all networks.
---@param _banner_auto_hide boolean|nil The banner will be automatically hidden if hide_banner was called after show_banner, but the banner did not have time to load. Default: `false`
function M.setup_banner(order, repeat_count, _banner_auto_hide)
    banner_auto_hide = _banner_auto_hide or false
    banner_mediator = mediator.create_mediator()
    mediator.setup(banner_mediator, networks, order, repeat_count)
end

---Initializes all networks.
---@param initialize_video boolean|nil check if need to initialize video networks
---@param initialize_banner boolean|nil check if need to initialize banner networks
---@param callback ads_callback|nil the function is called after execution.
---@param params table|nil additional parameters
function M.init(initialize_video, initialize_banner, callback, params)
    if M.is_initialized() then
        handle(callback, helper.success("Ads Wrapper already initialized"))
        return
    end
    initialized = true
    queues.init = create_init()
    queues.show_interstitial = create_show_interstitial()
    queues.load_interstitial = create_load_interstitial()
    queues.show_rewarded = create_show_rewarded()
    queues.load_rewarded = create_load_rewarded()
    queues.load_banner = create_load_banner()
    queues.unload_banner = create_unload_banner()
    queues.hide_banner = create_hide_banner()
    queues.show_banner = create_show_banner()

    if initialize_video or initialize_banner then
        local init_mediator = mediator.create_mediator()
        if initialize_video and video_mediator then
            mediator.add_networks(init_mediator, video_mediator)
        end
        if initialize_banner and banner_mediator then
            mediator.add_networks(init_mediator, banner_mediator)
        end
        mediator.call_all(init_mediator, queues.init, function(response)
            handle(callback, helper.success("Tried to initialize networks", response))
        end, params)
    else
        handle(callback, helper.success("Ads Wrapper initialized without networks"))
    end
end

---Initialize video networks
---@param callback ads_callback|nil the function is called after execution.
---@param params table|nil additional parameters
function M.init_video_networks(callback, params)
    if video_mediator then
        mediator.call_all(video_mediator, queues.init, callback, params)
    else
        mediator_error(VIDEO, callback)
    end
end

---Initialize banner networks
---@param callback ads_callback|nil the function is called after execution.
---@param params table|nil additional parameters
function M.init_banner_networks(callback, params)
    if banner_mediator then
        mediator.call_all(banner_mediator, queues.init, callback, params)
    else
        mediator_error(BANNER, callback)
    end
end

---Loads rewarded ads for next network
---@param callback ads_callback|nil the function is called after execution.
---@param params table|nil additional parameters
---@return integer|nil
function M.load_rewarded(callback, params)
    if M.is_video_setup() then
        return mediator.call_next(video_mediator, queues.load_rewarded, callback, params)
    else
        mediator_error(VIDEO, callback)
    end
    return nil
end

---Shows rewarded ads for next network
---@param callback ads_callback|nil the function is called after execution.
---@param params table|nil additional parameters
---@return integer|nil
function M.show_rewarded(callback, params)
    if M.is_video_setup() then
        return mediator.call(video_mediator, queues.show_rewarded, callback, params)
    else
        mediator_error(VIDEO, callback)
    end
    return nil
end

---Loads interstitial ads for next network
---@param callback ads_callback|nil the function is called after execution.
---@param params table|nil additional parameters
---@return integer|nil
function M.load_interstitial(callback, params)
    if M.is_video_setup() then
        return mediator.call_next(video_mediator, queues.load_interstitial, callback, params)
    else
        mediator_error(VIDEO, callback)
    end
    return nil
end

---Shows interstitial ads for next network
---@param callback ads_callback|nil the function is called after execution.
---@param params table|nil additional parameters
---@return integer|nil
function M.show_interstitial(callback, params)
    if M.is_video_setup() then
        return mediator.call(video_mediator, queues.show_interstitial, callback, params)
    else
        mediator_error(VIDEO, callback)
    end
    return nil
end

---Loads banner for for next network.
---@param callback ads_callback|nil the function is called after execution.
---@param params table|nil additional parameters
---@return integer|nil
function M.load_banner(callback, params)
    if M.is_banner_setup() then
        return mediator.call_next(banner_mediator, queues.load_banner, callback, params)
    else
        mediator_error(BANNER, callback)
    end
    return nil
end

---Shows setup banner for next network. Hides the previous banner if it was displayed.
---@param callback ads_callback|nil the function is called after execution.
---@param params table|nil additional parameters
---@return integer|nil
function M.show_banner(callback, params)
    if M.is_banner_setup() then
        banner_hidden = false
        return mediator.call(banner_mediator, queues.show_banner, function(response)
            if banner_auto_hide and banner_hidden then
                M.hide_banner()
            end
            handle(callback, response)
        end, params)
    else
        mediator_error(BANNER, callback)
    end
    return nil
end

---Hides setup banner for current network
---@param callback ads_callback|nil the function is called after execution.
---@param params table|nil additional parameters
function M.hide_banner(callback, params)
    if M.is_banner_setup() then
        banner_hidden = true
        mediator.call_current(banner_mediator, queues.hide_banner, callback, params)
    else
        mediator_error(BANNER, callback)
    end
end

---Unloads banner for current networks.
---@param callback ads_callback|nil the function is called after execution.
---@param params table|nil additional parameters
function M.unload_banner(callback, params)
    if M.is_banner_setup() then
        mediator.call_current(banner_mediator, queues.unload_banner, callback, params)
    else
        mediator_error(BANNER, callback)
    end
end

---Check if the banner mediator is set up
---@return boolean
function M.is_banner_setup()
    return banner_mediator ~= nil
end

---Check if the interstitial and rewarded video mediator is set up
---@return boolean
function M.is_video_setup()
    return video_mediator ~= nil
end

---Check if wrapper is initiailzed
---@return boolean
function M.is_initialized()
    return initialized
end

---Check if the interstitial video is loaded.
---Default checks the `next` network in mediator.
---@param check_current boolean|nil `Optional` if need check current network. Default `false`
---@param params table|nil additional parameters
---@return boolean
function M.is_interstitial_loaded(check_current, params)
    if not M.is_video_setup() then
        return false
    end
    local network = check_current and mediator.get_current_network(video_mediator) or mediator.get_next_network(video_mediator, true)
    return network and network.is_interstitial_loaded(params)
end

---Check if the rewarded video is loaded.
---Default checks the `next` network in mediator.
---@param check_current boolean|nil `Optional` if need check current network. Default `false`
---@param params table|nil additional parameters
---@return boolean
function M.is_rewarded_loaded(check_current, params)
    if not M.is_video_setup() then
        return false
    end
    local network = check_current and mediator.get_current_network(video_mediator) or mediator.get_next_network(video_mediator, true)
    return network and network.is_rewarded_loaded(params) or false
end

---Check if the banner is loaded.
---Default checks the `next` network in mediator.
---@param check_current boolean|nil `Optional` if need check current network. Default `false`
---@param params table|nil additional parameters
---@return boolean
function M.is_banner_loaded(check_current, params)
    if not M.is_banner_setup() then
        return false
    end
    local network = check_current and mediator.get_current_network(banner_mediator) or mediator.get_next_network(banner_mediator, true)
    return network and network.is_banner_loaded(params) or false
end

---Returns the current network pointed to by mediator
---Default returns for the video mediator
---@param check_banner boolean|nil `Optional` need to return mediator for banners. Default `false`
---@return ads_network|nil
function M.get_current_network(check_banner)
    local used_mediator = check_banner and banner_mediator or video_mediator
    if not used_mediator then
        return nil
    end
    local network = mediator.get_current_network(used_mediator)
    return network
end

---Returns the next network pointed to by mediator
---Default returns for the video mediator
---@param check_banner boolean|nil `Optional` need to return mediator for banners. Default `false`
---@return ads_network|nil
function M.get_next_network(check_banner)
    local used_mediator = check_banner and banner_mediator or video_mediator
    if not used_mediator then
        return nil
    end
    local network = mediator.get_next_network(used_mediator, true)
    return network
end

---Cancel execution
---@param id integer
function M.cancel(id)
    mediator.cancel(id)
end

return M
