# influxer

influxer is a simple tool to observe messages published to an [mqtt][mqtt]
broker and store them in [influxdb][influxdb].

This is a tool I built for myself and my own readings because existing
tools were too complicated and I wanted something I could understand.

## QuickStart

Here's a really simple example to get you started:

```
from mqtt://your.mqtt.broker/#clientid {
    watch "home/kitchen/temperature" float [site="myhouse", room="kitchen"] field="temperature" measurement="env"
}
```

In the example, you can see the kitchen thermometer is being read and
stored in an influxdb measurement called `env` with numeric value of
the reading being stored as the field `temperature` with the tags
`myhouse` and `kitchen`.  Allowing you to issue queries like:

    select last(temperature) from env where room='kitchen'

...if you have a lot of thermometers deployed like that, you can use
topic wildcards and positional variables for mapping back to tags.
e.g., the following is similar, but supports all rooms:

```
from mqtt://your.mqtt.broker/#clientid {
    watch "home/+/thermometer" float [site="myhouse", room=$2] field="temperature" measurement="env"
}
```

For a more advanced example, if you have `temperature` *and*
`humidity` sensors in the same form, you can do the following:

```
from mqtt://your.mqtt.broker/#clientid {
    watch "home/+/+" float [site="myhouse", room=$2] field=$3 measurement="env"
}
```

In practice, I end up with a lot of patterns I'm observing, so I tend
to use `match` instead of `watch`.  `match` is like `watch`, but
doesn't subscribe.  So I'll often do something that looks more like
this:

```
from mqtt://your.mqtt.broker/#clientid {
    // Only put temperature and humidity readings into the env measurement
    match "home/+/temperature" float [site="myhouse", room=$2] field=$3 measurement="env"
    match "home/+/humidity" float [site="myhouse", room=$2] field=$3 measurement="env"

    match "home/+/battery" int [site="myhouse", thing=$2] measurement="battery"

    // This causes us to subscribe to everything under home, but
    // anything not explicitly matched is ignored.
    watch "home/#" ignore
}
```

We also support JSON via [jsonpointer][jsonpointer] for parsing fields
out of JSON payloads.  For example, if you use [tasmota][tasmota] with
something like POWR2 sensor/switches, you get a lot of interesting
telemetry reported like this:

```json
{
  "Time": "2021-07-03T10:41:53",
  "ENERGY": {
    "TotalStartTime": "2019-01-16T05:53:10",
    "Total": 459.394,
    "Yesterday": 0.667,
    "Today": 0.223,
    "Period": 0,
    "Power": 0,
    "ApparentPower": 0,
    "ReactivePower": 0,
    "Factor": 0,
    "Voltage": 119,
    "Current": 0
  }
}
```

This is useful data, so let's build on our previous example to import
it:

```
from mqtt://your.mqtt.broker/#clientid {
    // Only put temperature and humidity readings into the env measurement
    match "home/+/temperature" float [site="myhouse", room=$2] field=$3 measurement="env"
    match "home/+/humidity" float [site="myhouse", room=$2] field=$3 measurement="env"

    match "home/+/battery" int [site="myhouse", thing=$2] measurement="battery"

    match "home/+/tele/SENSOR" jsonp {
          measurement "pow" [which=$1]
          "total"      <- "/ENERGY/Total"
          "yesterday"  <- "/ENERGY/Yesterday"
          "today"      <- "/ENERGY/Today"
          "power"      <- "/ENERGY/Power"
          "voltage"    <- "/ENERGY/Voltage"
          "current"    <- "/ENERGY/Current"
    }


    // This causes us to subscribe to everything under home, but
    // anything not explicitly matched is ignored.
    watch "home/#" ignore
}
```

## Config Syntax

The config is a series of blocks that are specific to an mqtt
connection.  If you want to observe multiple mqtt brokers, or just
have different client auth requirements, go for it.

Each block starts with the literal string "from" followed by an MQTT
URL and then the collection of watches for that source.

Matches and watches are the same syntax and concept.  The only
difference between `match` and `watch` is whether an explicit
subscription is requested for the item.  As shown in quickstart, a
blanket `watch` near the bottom can simplify subscriptions a bit.

Each item consists of an optional QoS, a filter, and an extractor.
The default QoS is 2, but `qos0` `qos1` or `qos2` may be specified
between the literal `watch` and the filter if your needs are
different.

After the topic, you specify your extractor.  There are three matcher
types:

### Ignore

Ignore is what it sounds like, and lets you ignore topics that your
watch may have picked up, but don't provide any useful value.  In the
quick start examples, it's the catch-all for the broad watch, allowing
influxer to see all of the messages, but ignore the ones it doesn't
have specific plans for.

### Simple Value

The simple value parser is meant for processing topics that send
single values per topic.  (e.g., your thermometer just sends `25` for
the temperature).  A handful of parsers are available for mapping to
useful influxdb fields:

* int
* float
* bool
* string
* auto

Most of these are fairly obvious.  `auto` means approximately the same
thing as `float` currently as that's what sensor values often end up
looking like.  If you're unsure, you can be explicit.

Tags are optional, but are generally quite useful string values
attached to rows in influxdb to allow you to discriminate values in
queries.  You specify them by adding `[tag1="val", tag2="val"]` after
the value parser.  Tag values can reference topic segments using `$X`
for topic field position `X` (one-based).  e.g., if the topic is
`home/bedroom/thermometer`, then `$1` is `home` and `$2` is `bedroom`,
etc...

Next, you specify the influxdb field that will receive the value.  The
default is `value`, otherwise you can specify `field="temperature"` or
use a topic field position.

Finally, you can specify the measurement.  The default is the full
name of the topic, which is probably not great, but it makes it easy
to grab all the things with minimal effort.

Here are are a few complete example:

```
watch "a/b/c" auto
watch qos0 "some/thing" int measurement="things"
watch "+/temp" field=$1 measurement="temps"
watch "+/+/+" [sensor=$2] field=$3 measurement=$1
```

### JSON

The JSON extractor allows field extractions using
[jsonpointer][jsonpointer] to nest multiple influxdb values into a
single mqtt message handler.

It's somewhat related to the Simple Value parser, but the measurement
and tags are shared for the entire block, and JSON values are pulled
into explicitly named fields.  The format is `jsonp { ... }` where
`...` contains

    measurement "mname" [tag1="tagv"]
    "field1" <- "/json/path" auto
    "field2" <- "/json/path2"
    "field3" <- "/json/path3" int

Both `"mname"` and `"tagv"` can use `$` topic vars and tags may be
omitted if you don't want any.

After your measurement declaration, we have one or more specific field
extractors in the form of:

    "fieldname" <- "/json/path" auto

`auto` may be omitted or replaced with any other simple value parser.

[mqtt]: https://mqtt.org
[influxdb]: https://www.influxdata.com
[jsonpointer]: https://datatracker.ietf.org/doc/html/rfc6901
[tasmota]: https://tasmota.github.io/docs/
