###
A Coffeescript WebRTC snowflake proxy
Using Copy-paste signaling for now.

Uses WebRTC from the client, and websocket to the server.

Assume that the webrtc client plugin is always the offerer, in which case
this must always act as the answerer.
###
DEFAULT_BROKER = 'snowflake-reg.appspot.com'
DEFAULT_RELAY =
  host: '192.81.135.242'
  port: 9902
COPY_PASTE_ENABLED = false

DEBUG = false
silenceNotifications = false
query = Query.parse(location)
DEBUG = Params.getBool(query, 'debug', false)
COPY_PASTE_ENABLED = Params.getBool(query, 'manual', false)

# Bytes per second. Set to undefined to disable limit.
DEFAULT_RATE_LIMIT = DEFAULT_RATE_LIMIT || undefined
MIN_RATE_LIMIT = 10 * 1024
RATE_LIMIT_HISTORY = 5.0
DEFAULT_BROKER_POLL_INTERVAL = 5.0 * 1000

MAX_NUM_CLIENTS = 1
CONNECTIONS_PER_CLIENT = 1

# TODO: Different ICE servers.
config = {
  iceServers: [
    { urls: ['stun:stun.l.google.com:19302'] }
  ]
}

# Janky state machine
MODE =
  INIT:              0
  WEBRTC_CONNECTING: 1
  WEBRTC_READY:      2

CONFIRMATION_MESSAGE = "You're currently serving a Tor user via Snowflake."

# Minimum viable snowflake for now - just 1 client.
class Snowflake

  relayAddr:  null
  proxyPairs: []
  rateLimit:  null
  state:      MODE.INIT
  retries:    0

  constructor: (@broker, @ui) ->
    rateLimitBytes = undefined
    if 'off' != query['ratelimit']
      rateLimitBytes = Params.getByteCount(query, 'ratelimit',
                                           DEFAULT_RATE_LIMIT)
    if undefined == rateLimitBytes
      @rateLimit = new DummyRateLimit()
    else
      @rateLimit = new BucketRateLimit(rateLimitBytes * RATE_LIMIT_HISTORY,
                                       RATE_LIMIT_HISTORY)
    @retries = 0

  # TODO: Should potentially fetch from broker later.
  # Set the target relay address spec, which is expected to be a websocket
  # relay.
  setRelayAddr: (relayAddr) ->
    @relayAddr = relayAddr
    log 'Using ' + relayAddr.host + ':' + relayAddr.port + ' as Relay.'
    log 'Input offer from the snowflake client:' if COPY_PASTE_ENABLED
    return true

  # Initialize WebRTC PeerConnection
  beginWebRTC: ->
    @state = MODE.WEBRTC_CONNECTING
    for i in [1..CONNECTIONS_PER_CLIENT]
      @makeProxyPair @relayAddr
    return if COPY_PASTE_ENABLED
    log 'ProxyPair Slots: ' + @proxyPairs.length
    log 'Snowflake IDs: ' + (@proxyPairs.map (p) -> p.id).join ' | '
    @pollBroker()

  # Regularly poll Broker for clients to serve until this snowflake is
  # serving at capacity, at which point stop polling.
  pollBroker: ->
    # Temporary countdown. TODO: Simplify
    countdown = (msg, sec) =>
      @ui.setStatus msg + ' (Polling in ' + sec + ' seconds...)'
      sec--
      if sec >= 0
        setTimeout((-> countdown(msg, sec)), 1000)
      else
        findClients()
    # Poll broker for clients.
    findClients = =>
      pair = @nextAvailableProxyPair()
      if !pair
        log 'At client capacity.'
        # Do nothing until a new proxyPair is available.
        return
      msg = 'polling for client... '
      msg += '[retries: ' + @retries + ']' if @retries > 0
      @ui.setStatus msg
      recv = @broker.getClientOffer pair.id
      recv.then (desc) =>
        @receiveOffer pair, desc
        countdown('Serving 1 new client.', DEFAULT_BROKER_POLL_INTERVAL / 1000)
      , (err) ->
        countdown(err, DEFAULT_BROKER_POLL_INTERVAL / 1000)
      @retries++

    findClients()

  # Returns the first ProxyPair that's available to connect.
  nextAvailableProxyPair: ->
    return @proxyPairs.find (pp, i, arr) -> return !pp.active

  # Receive an SDP offer from some client assigned by the Broker,
  # |pair| - an available ProxyPair.
  receiveOffer: (pair, desc) =>
    console.assert !pair.active
    try
      offer = JSON.parse desc
      dbg 'Received:\n\n' + offer.sdp + '\n'
      console.log offer
      sdp = new SessionDescription offer
      @sendAnswer pair if pair.receiveWebRTCOffer sdp
    catch e
      log 'ERROR: Unable to receive Offer: ' + e

  sendAnswer: (pair) ->
    next = (sdp) ->
      dbg 'webrtc: Answer ready.'
      pair.pc.setLocalDescription sdp
    fail = ->
      dbg 'webrtc: Failed to create Answer'
    promise = pair.pc.createAnswer next, fail
    promise.then next if promise

  makeProxyPair: (relay) ->
    pair = new ProxyPair null, relay, @rateLimit
    @proxyPairs.push pair
    pair.onCleanup = (event) =>
      # Delete from the list of active proxy pairs.
      @proxyPairs.splice(@proxyPairs.indexOf(pair), 1)
      @pollBroker()
    pair.begin()

  # Stop all proxypairs.
  cease: ->
    while @proxyPairs.length > 0
      @proxyPairs.pop().close()

  disable: ->
    log 'Disabling Snowflake.'
    @cease()

  die: ->
    log 'Snowflake died.'
    @cease()

  # Close all existing ProxyPairs and begin finding new clients from scratch.
  reset: ->
    @cease()
    log 'Snowflake resetting...'
    @retries = 0
    @beginWebRTC()

snowflake = null

# Signalling channel - just tells user to copy paste to the peer.
# Eventually this should go over the broker.
Signalling =
  send: (msg) ->
    log '---- Please copy the below to peer ----\n'
    log JSON.stringify msg
    log '\n'

  receive: (msg) ->
    recv = ''
    try
      recv = JSON.parse msg
    catch e
      log 'Invalid JSON.'
      return
    desc = recv['sdp']
    if !desc
      log 'Invalid SDP.'
      return false
    pair = snowflake.nextAvailableProxyPair()
    if !pair
      log 'At client capacity.'
      return false
    snowflake.receiveOffer pair, msg

# Log to both console and UI if applicable.
log = (msg) ->
  console.log 'Snowflake: ' + msg
  snowflake.ui.log msg

dbg = (msg) -> log msg if true == snowflake.ui.debug

init = ->
  ui = new UI()
  silenceNotifications = Params.getBool(query, 'silent', false)
  brokerUrl = Params.getString(query, 'broker', DEFAULT_BROKER)
  broker = new Broker brokerUrl
  snowflake = new Snowflake broker, ui

  log '== snowflake proxy =='
  log 'Copy-Paste mode detected.' if COPY_PASTE_ENABLED
  dbg 'Contacting Broker at ' + broker.url if not COPY_PASTE_ENABLED

  relayAddr = Params.getAddress(query, 'relay', DEFAULT_RELAY)
  snowflake.setRelayAddr relayAddr
  snowflake.beginWebRTC()

# Notification of closing tab with active proxy.
# TODO: Opt-in/out parameter or cookie
window.onbeforeunload = ->
  if !silenceNotifications && MODE.WEBRTC_READY == snowflake.state
    return CONFIRMATION_MESSAGE
  null

window.onunload = ->
  pair.close() for pair in snowflake.proxyPairs
  null

window.onload = init
