###
# ItemController.coffee
#
# Serves routes for items. i.e. Any url that contains one or more ids.
#
# @author: Emanuel Lauria <emanuel.lauria@zalando.de>
###

# Requirements

fs    = require 'fs'
_     = require 'underscore'
async = require 'async'
im    = require "imagemagick"
mime  = require "mime-magic"

# Server settings
settings = require "#{__dirname}/../server.settings.coffee"

# Solr Manager to add/remove solr suffixes
SolrManager = require './solrManager.coffee'

Schema = require './schema.coffee'

class ItemController


    module.exports = ItemController


    # Routes
    constructor: (app, auth) ->

        # Get a single item
        app.get     "/:entity/collection/:id",  auth, (a...) => @get    a...

        # Create a new item
        app.post    "/:entity/collection",      auth, (a...) => @post   a...

        # Update an existing item
        app.put     "/:entity/collection/:id",  auth, (a...) => @put    a...

        # Remove an item
        app.delete  "/:entity/collection/:id",  auth, (a...) => @delete a...

        # Return one field from an item
        app.get     "/:entity/:item/property/:property", auth, (a...) => @prop   a...

        # Put a value in an items property
        app.put     "/:entity/:item/property/:property/:value", auth, (a...) =>
            @putValue  a...

        # Put a value in an items property
        app.delete  "/:entity/:item/property/:property/:value", auth, (a...) =>
            @delValue  a...


    # Get an item or an array of items from IDs
    get: (req, res) =>

        name = req.params.entity
        solrManager = new SolrManager name
        id = req.params.id.split('|')

        # Return just 1 item
        if id.length is 1 then return solrManager.getItemById id[0], (docs) ->
            res.send docs

        # Return an array of items
        docs = []
        async.forEach id, (id, cb) =>
            solrManager.getItemById name, id, (item) ->
                docs.push item[0]
                cb()
        , (err) ->
            throw err if err
            return res.send docs


    # Create a new item
    post: (req, res) =>

        name = req.params.entity
        solrManager = new SolrManager name
        schema = solrManager.schema
        id = @generateId()
        picKey = schema.getFieldsByType('img')[0]?.id

        # Cube link fields need to be a list of IDs to be saved
        @resetClinkFields schema, req.body

        # Create a new item with id
        item = _.extend {id: id}, req.body

        response = null

        async.series [

            (cb) =>

                tokenFields = schema.getFieldsByProp 'token'
                return cb() unless tokenFields.length

                fid = tokenFields[0]?.id
                return cb() unless fid

                value = item[fid]
                return cb() unless value

                async.each value, (v, _cb) =>

                    return _cb() unless v

                    solrManager.getItemsByProp fid, v, (items) =>
                        docs = []
                        _.each items, (item, __cb) =>
                            return if item.id is item.id
                            item[fid] = _.without item[fid], v
                            delete item[fid] if item[fid].length is 0
                            docs.push item

                        solrManager.addItems docs, (docs) =>
                            _cb()

                , (err, result) =>
                    throw err if err
                    cb()



            , (cb) =>
                return cb() if item[picKey]

                solrManager.addItems item, (item) =>
                    response = item[0]
                    cb()

            , (cb) =>
                return cb() if response

                # Get pic url
                tmp_pic = "#{__dirname}/../public/#{item[picKey]}"
                target_file = "#{id}.jpg"
                target_path = "#{__dirname}/../public/images/#{name}/#{target_file}"

                # Move the picture to its final place and send item object back
                fs.rename tmp_pic, target_path, (err) =>
                    return cb err if err
                    item[picKey] = "/images/#{name}/#{target_file}" unless err
                    solrManager.addItems item, (item) =>
                        response = item[0]
                        return cb()

        ], (err, result) =>
            throw err if err

            res.send response


    # Update an item
    put: (req, res) =>

        name = req.params.entity
        eSettings = require "../entities/#{name}/settings.json"
        solrManager = new SolrManager name
        schema = solrManager.schema
        picKey = schema.getFieldsByType('img')[0]?.id
        item = null
        response = null

        # Cube link fields need to be a list of IDs to be saved
        @resetClinkFields schema, req.body

        async.series [

            (cb) =>
                # Get item from the id on the querystring
                solrManager.getItemById req.params.id, (result) =>
                    item = result[0]
                    cb()

            , (cb) =>
                # Detect concurrency issues and respond 409 in case.
                if !@isVersionValid item, req.body
                    res.statusCode = 409
                    response = {}
                    return cb()
                cb()

            , (cb) =>

                # Remove this item's token values from all other items.
                return cb() if response

                tokenFields = schema.getFieldsByProp 'token'
                return cb() unless tokenFields.length

                fid = tokenFields[0]?.id
                return cb() unless fid

                value = req.body[fid]
                return cb() unless value

                async.each value, (v, _cb) =>

                    return _cb() unless v

                    solrManager.getItemsByProp fid, v, (items) =>
                        docs = []
                        _.each items, (item, __cb) =>
                            return if item.id is req.body.id
                            item[fid] = _.without item[fid], v
                            delete item[fid] if item[fid].length is 0
                            docs.push item

                        solrManager.addItems docs, (docs) =>
                            _cb()

                , (err, result) =>
                    throw err if err
                    cb()

            , (cb) =>
                return cb() if response

                return cb() unless req.user

                # Update all fields if user is admin
                if @isAdmin req.user.mail, eSettings.admins
                    item = req.body
                    return cb()

                # If the user isnt admin, only update additional fields
                _.each solrManager.schema.getFieldsByProp('additional'), (field) =>
                    item[field.id] = req.body[field.id] if req.body[field.id]
                cb()

            , (cb) =>
                return cb() if response

                # Ready to add items to db if they don't have a picture
                return cb() unless req.body[picKey] is item[picKey]

                response = item

                solrManager.addItems req.body, (item) =>
                    cb()

            , (cb) =>
                return cb() if response

                # Update picture field and add items to db
                @updatePic item.id, name, req.body[picKey], item[picKey], (path) =>
                    req.body[picKey] = path
                    solrManager.addItems req.body, (item) =>
                        response = item
                        cb()

        ], (err, result) ->
            throw err if err

            # Ready to send the response back to backbone app
            res.send response


    # Remove item and its picture (if it has).
    delete: (req, res) =>
        name = req.params.entity
        id = req.params.id
        solrManager = new SolrManager name
        schema = solrManager.schema
        picKey = schema.getFieldsByType('img')[0]?.id

        solrManager.getItemById id, (docs) =>
            _.each docs, (item) ->
                solrManager.client.deleteByID id, (err, result) ->
                    throw err if err
                    res.send result
                return unless picKey
                imgPath = "#{__dirname}/../public/#{item[picKey]}"
                fs.unlink imgPath, (err) ->
                    console.log "Failed to remove pic for user #{id}" if err


    # Get the value of a property from one specific item
    prop: (req, res) =>
        entity  = req.params.entity
        item    = req.params.item
        prop    = req.params.property
        solrManager = new SolrManager entity
        solrManager.getItemById item, (items) ->
            return res.send [] unless items.length
            res.send items[0][prop]


    # Set or insert a value on a property from an item
    putValue: (req, res) =>

        entity  = req.params.entity
        item    = req.params.item
        prop    = req.params.property
        value   = req.params.value

        Verify  = require("../entities/#{entity}/code.coffee").Verify

        unless Verify
            res.statusCode = 403
            return res.send "Not allowed"

        # Check if its allowed to make this change
        verify = new Verify req

        verify.isAllowed (allowed) =>

            unless allowed
                res.statusCode = 403
                return res.send "Not allowed"

            solrManager = new SolrManager entity

            solrManager.getItemById item, (items) =>
                return res.send [] unless items.length

                item = items[0]

                item[prop] = [] unless item[prop]

                if typeof item[prop] is typeof []
                    item[prop].push value if item[prop].indexOf(value) is -1
                    return solrManager.addItems item, (item) =>
                        res.send item

                item[prop] = value
                solrManager.addItems item, (item) =>
                    res.send item


    # Delete a value from an item
    delValue: (req, res) =>

        entity  = req.params.entity
        item    = req.params.item
        prop    = req.params.property
        value   = req.params.value

        Verify  = require("../entities/#{entity}/code.coffee").Verify

        unless Verify
            res.statusCode = 403
            return res.send "Not allowed"

        # Check if its allowed to make this change
        verify = new Verify req


        verify.isAllowed (allowed) =>

            if not allowed
                res.statusCode = 403
                return res.send "Not allowed"

            solrManager = new SolrManager entity

            solrManager.getItemById item, (items) =>
                return res.send [] unless items.length

                item = items[0]

                return res.send [] unless item[prop]

                if value

                    index = item[prop].indexOf value

                    return res.send [] if index is -1

                    item[prop].splice index, 1
                    return solrManager.addItems item, (_item) =>
                        res.send _item

                delete item[prop]
                solrManager.addItems item, (_item) =>
                    res.send _item


    # Update picture removing old picture and renaming new one.
    updatePic: (id, name, bodyPic, itemPic, cb) =>
        tmp_pic = "#{__dirname}/../public/#{bodyPic}"
        rnd = bodyPic.slice(21, 24)
        target_file = "/images/#{name}/#{id}_#{rnd}.jpg"
        target_path = "#{__dirname}/../public/#{target_file}"

        fs.stat tmp_pic, (err, stat) ->
            if err then console.log "ERROR[uid=#{id}]: No uploaded picture"
            fs.unlink "#{__dirname}/../public/#{itemPic}", (err) ->
                fs.rename tmp_pic, target_path, (err) ->
                    throw err if err
                    cb target_file


    # Get the value of a property from one specific item
    prop: (req, res) =>

        entity  = req.params.entity
        item    = req.params.item
        prop    = req.params.property

        solrManager = new SolrManager entity

        solrManager.getItemById item, (items) ->
            return res.send [] unless items.length
            res.send items[0][prop]


    # Set or insert a value on a property from an item
    putValue: (req, res) =>

        entity  = req.params.entity
        item    = req.params.item
        prop    = req.params.property
        value   = req.params.value

        Verify  = require("../entities/#{entity}/code.coffee").Verify

        unless Verify
            res.statusCode = 403
            return res.send "Not allowed"

        # Check if its allowed to make this change
        verify = new Verify req

        verify.isAllowed (allowed) =>

            unless allowed
                res.statusCode = 403
                return res.send "Not allowed"

            solrManager = new SolrManager entity

            solrManager.getItemById item, (items) =>
                return res.send [] unless items.length

                item = items[0]

                item[prop] = [] unless item[prop]

                if typeof item[prop] is typeof []
                    item[prop].push value if item[prop].indexOf(value) is -1
                    return solrManager.addItems item, (item) =>
                        res.send item

                item[prop] = value
                solrManager.addItems item, (item) =>
                    res.send item


    # Delete a value from an item
    delValue: (req, res) =>

        entity  = req.params.entity
        item    = req.params.item
        prop    = req.params.property
        value   = req.params.value

        Verify  = require("../entities/#{entity}/code.coffee").Verify

        unless Verify
            res.statusCode = 403
            return res.send "Not allowed"

        # Check if its allowed to make this change
        verify = new Verify req


        verify.isAllowed (allowed) =>

            if not allowed
                res.statusCode = 403
                return res.send "Not allowed"

            solrManager = new SolrManager entity

            solrManager.getItemById item, (items) =>
                return res.send [] unless items.length

                item = items[0]

                return res.send [] unless item[prop]

                if value

                    index = item[prop].indexOf value

                    return res.send [] if index is -1

                    item[prop].splice index, 1
                    return solrManager.addItems item, (_item) =>
                        res.send _item

                delete item[prop]
                solrManager.addItems item, (_item) =>
                    res.send _item


    # Transform a list of items into a list of ids, which is what it actually
    # gets stored in the DB for cube link fields.
    resetClinkFields: (schema, item) =>

        _.each schema.getFieldsByType('clink'), (field) =>
            oarr = []
            _.each item[field.id], (i) =>
                oarr.push i.id if oarr.indexOf(i.id) is -1

            item[field.id] = oarr


    # Generate an ID for the item on the db
    generateId: () ->
        chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        today = new Date()
        result = today.valueOf().toString 16
        result += chars.substr Math.floor(Math.random() * chars.length), 1
        result += chars.substr Math.floor(Math.random() * chars.length), 1
        result


    # Check version match for concurrency issues
    isVersionValid: (reqItem, dbItem) =>
        return yes unless dbItem['_version'] and reqItem['_version_']
        dbTimestamp  = new Date dbItem['_version_']
        reqTimestamp = new Date reqItem['_version_']
        if reqTimestamp < dbTimestamp
            return no
        yes


    # Check if id is in list
    isAdmin: (id, list) =>
        return yes unless list
        return yes if list.indexOf(id) isnt -1
        no
