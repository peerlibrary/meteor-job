############################################################################
#     Copyright (C) 2014 by Vaughn Iverson
#     meteor-job-class is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

# Exports Job object

class Job

  @jobPriorities:
    low: 10
    normal: 0
    medium: -5
    high: -10
    critical: -15

  @jobStatuses: [
    'waiting'
    'ready'
    'running'
    'failed'
    'cancelled'
    'completed'
  ]

  # Automatically work within Meteor, otherwise see @setDDP below
  @ddp_apply: Meteor?.apply

  # Class methods

  # This needs to be called when not running in Meteor to use the local DDP connection.
  @setDDP: (ddp) ->
    if ddp? and ddp.call?
      @ddp_apply = ddp.call.bind ddp
    else
      console.error "Bad ddp object in Job.setDDP()"

  # Creates a job object by id from the server queue root
  # returns null if no such job exists
  @getJob: (root, id, cb) ->
    if cb and typeof cb is 'function'
      @ddp_apply "getJob_#{root}", [id], (err, doc) =>
        return cb err if err
        if doc
          job = new Job root, doc.type, doc.data, doc
          return cb null, job
        else
          return cb null, null
    else
      doc = @ddp_apply "getJob_#{root}", [id]
      if doc
        job = new Job root, doc.type, doc.data, doc
        return job
      else
        return null

  # Creates a job object by reserving the next available job of
  # the specified 'type' from the server queue root
  # returns null if no such job exists
  @getWork: (root, type, cb) ->
    if cb and typeof cb is 'function'
      @ddp_apply "getWork_#{root}", [type], (err, doc) =>
        return cb err if err
        if doc
          job = new Job root, doc.type, doc.data, doc
          return cb null, job
        else
          return cb null, null
    else
      doc = @ddp_apply "getWork_#{root}", [type]
      if doc
        job = new Job root, doc.type, doc.data, doc
        return job
      else
        return null

  # Job class instance constructor. When "new Job(...)" is run
  constructor: (@root, type, data, doc = null) ->
    unless @ instanceof Job
      return new job @root, type, data
    @ddp_apply = Job.ddp_apply
    unless typeof doc is 'object' and
           typeof data is 'object' and
           typeof type is 'string' and
           typeof @root is 'string'
      console.error "new Job: bad parameter(s), #{@root} #{type}, #{data}, #{doc}"
      return null
    else if doc?  # This case is used to create local Job objects from DDP calls
      unless @_doc.type is type and @_doc.data is data
        console.error "rebuild Job: bad parameter(s), #{@root} #{type}, #{data}, #{doc}"
        return null
      @_doc = doc
      @.data = data
    else  # This is the normal "create a new object" case
      @_doc =
        id: null
        runId: null
        type : type
        data: data
        status: 'waiting'
        updated: new Date()
      @priority().attempts().after().progress().depends().log("Created")
      @.data = @_doc.data  # Make data a little easier to get to
      return @

  # Adds a run dependancy on one or more existing jobs to this job
  depends: (jobs) ->
    if jobs? and typeof jobs is 'object'
      if jobs instanceof Job and jobs._doc._id?
        depends = [ jobs._doc._id ]
      else if jobs instanceof Array
        depends = []
        for j in jobs when j instanceof Job and j._doc._id?
          depends.push j._doc._id
    else
      depends = []
    @_doc.depends = depends
    return @

  # Set the run priority of this job
  priority: (level = 0, cb) ->
    if typeof level is 'string'
      priority = Job.jobPriorities[level] ? 0
    else if typeof level is 'number'
      priority = level
    else
      priority = 0

    @_doc.priority = priority
    return @

  # Sets the number of attempted runs of this job and
  # the time to wait between successive attempts
  attempts: (num = 1, msWait = 5*60*1000) ->
    if typeof num is 'number' and num >= 1
      attempts = num
    else
      attempts = 1
    if typeof msWait is 'number' and msWait >= 0
      attemptsWait = msWait
    else
      attemptsWait = 5*60*1000

    @_doc.attempts = attempts
    @_doc.attemptsWait = attemptsWait
    @_doc.attempted ?= 0
    return @

  # Sets the delay before this job can run after it is saved
  delay: (milliseconds = 0, cb) ->
    unless typeof milliseconds is 'number' and milliseconds >= 0
      milliseconds = 0
    if typeof milliseconds is 'number' and milliseconds >= 0
      return @after new Date(new Date().valueOf() + milliseconds), cb
    else
      return @after new Date(), cb

  # Sets a time after which this job can run once it is saved
  after: (time, cb) ->
    if typeof time is 'object' and time instanceof Date
      after = time
    else
      after = new Date()
    @_doc.after = after
    return @

  # Write a message to this job's log.
  log: (message, cb) ->
    if @_doc._id?
      if cb and typeof cb is 'function'
        @ddp_apply "jobLog_#{@root}", [@_doc._id, @_doc.runId, message], (err, res) =>
          return cb err if err
          return cb null, res
      else
        res = @ddp_apply "jobLog_#{@root}", [@_doc._id, @_doc.runId, message]
        return res
    else
      @_doc.log ?= []
      @_doc.log.push { time: new Date(), runId: null, message: message }
      return @

  # Indicate progress made for a running job. This is important for
  # long running jobs so the scheduler doesn't assume they are dead
  progress: (completed = 0, total = 1, cb) ->
    if (typeof completed is 'number' and
        typeof total is 'number' and
        completed >= 0 and
        total > 0 and
        total >= completed)
      progress = { completed: completed, total: total, percent: 100*completed/total }
      if @_doc._id? and @_doc.runId?
        if cb and typeof cb is 'function'
          @ddp_apply "jobProgress_#{@root}", [@_doc._id, @_doc.runId, progress], (err, res) =>
            return cb err if err
            @_doc.progress = progress
            return cb null, res
        else
          res = @ddp_apply "jobProgress_#{@root}", [@_doc._id, @_doc.runId, progress]
          @_doc.progress = progress
          return res
      else
        @_doc.progress = progress
        return @
    else
      console.warn "job.progress: something's wrong with progress: #{@id}, #{completed} out of #{total}"
    return null

  # Save this job to the server job queue Collection it will also resave a modified job if the
  # job is not running and hasn't completed.
  save: (cb) ->
    console.log "About to submit a job"
    if cb and typeof cb is 'function'
      @ddp_apply "jobSubmit_#{@root}", [@_doc], (err, id) =>
        return cb err if err
        @_doc._id = id
        return cb null, id
      return true
    else
      id = @ddp_apply "jobSubmit_#{@root}", [@_doc]
      @_doc._id = id
      return id

  # Refresh the local job state with the server job queue's version
  refresh: (cb) ->
    if @_doc._id?
      if cb and typeof cb is 'function'
        @ddp_apply "getJob_#{@root}", [@_doc._id], (err, doc) =>
          return cb err if err
          return cb new Error "Refresh failed, doc not found" unless doc?
          @_doc = doc
          return cb null, true
      else
        doc = @ddp_apply "getJob_#{@root}", [@_doc._id]
        if doc?
          @_doc = doc
          return true
        else
          return false
    else
      console.warn "Can't refresh an unsaved job"
      return false

  # Fetches a job's current log array by id from the server
  # queue root returns null if no such job exists
  getLog: (cb) ->
    if cb and typeof cb is 'function'
      @ddp_apply "getLog_#{@root}", [@_doc.id], (err, doc) =>
        return cb err if err
        return cb new Error "Refresh failed, doc not found"
        unless doc?
          return cb null, doc.log
        else
          return cb null, null
    else
      doc = @ddp_apply "getLog_#{@root}", [@_doc.id]
      if doc
        return doc.log
      else
        return null

  # Indicate to ther server than this run has finished. If it failed, provide an error message.
  done: (err, cb) ->
    if @_doc._id? and @_doc.runId?
      if cb and typeof cb is 'function'
        @ddp_apply "jobDone_#{@root}", [@_doc._id, @_doc.runId, err, @attemptsWait], (err, res) =>
        return cb err if err
        return cb null, res
      else
        res = @ddp_apply "jobDone_#{@root}", [@_doc._id, @_doc.runId, err, @attemptsWait]
        return res
    else
      console.warn "Can't finish an unsaved job"
    return null

  # Cancel this job if it is running or able to run (waiting, ready)
  cancel: (cb) ->
    if @_doc._id?
      if cb and typeof cb is 'function'
        @ddp_apply "jobCancel_#{@root}", [@_doc._id], (err, res) =>
        return cb err if err
        return cb null, res
      else
        res = @ddp_apply "jobCancel_#{@root}", [@_doc._id]
        return res
    else
      console.warn "Can't cancel an unsaved job"
    return null

  # Restart a failed or cancelled job
  restart: (params..., cb) ->
    attempts = params?[0] ? 1
    if @_doc._id?
      if cb and typeof cb is 'function'
        @ddp_apply "jobRestart_#{@root}", [@_doc._id, attempts], (err, res) =>
        return cb err if err
        return cb null, res
      else
        res = @ddp_apply "jobRestart_#{@root}", [@_doc._id, attempts]
        return res
    else
      console.warn "Can't restart an unsaved job"
    return null

  # Remove a job that is not able to run (completed, cancelled, failed) from the queue
  remove: (cb) ->
    if @_doc._id?
      if cb and typeof cb is 'function'
        @ddp_apply "jobRemove_#{@root}", [@_doc._id], (err, res) =>
        return cb err if err
        return cb null, res
      else
        res = @ddp_apply "jobRemove_#{@root}", [@_doc._id]
        return res
    else
      console.warn "Can't remove an unsaved job"
    return null

# Export Job in a npm package
if module?.exports?
  module.exports = Job
