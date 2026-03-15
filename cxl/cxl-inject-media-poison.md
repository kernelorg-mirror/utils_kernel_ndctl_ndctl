---
layout: page
---

# NAME

cxl-inject-media-poison - Inject poison into CXL memory

# SYNOPSIS

>     cxl inject-media-poison <memdev> [<options>]

<div class="warning">

Poison injection can cause system instability and should only be used
for debugging hardware and software error recovery flows. Use at your
own risk!

</div>

Inject poison into a CXL memory device’s memory. CXL memdevs can be
specified by device name (e.g. "mem0"), device id ("X" in "memX"), or
host device name ("0000:35:00.0").

Poison can only be used with CXL memory devices with poison injection
support. To see which CXL devices support poison injection, see the
"poison_injectable" attribute under the device in *cxl-list*. An example
of a device that supports poison injection:

    # cxl list -u -m mem0
    {
        "memdev":"mem0",
        "ram_size":"256.00 MiB (268.44 MB)",
        "serial":"0",
        "host":"0000:0d:00.0",
        "firmware_version":"BWFW VERSION 00",
        "poison_injectable":true
    }

A device physical address is required for poison injection. The
*-a*/*--address* option is used to specify the device physical address
to inject poison to. The address can be given in either decimal or
hexadecimal. For example:

    # cxl inject-media-poison mem0 -a 0x1000
    poison inject at mem0:0x1000
    # cxl list -m mem0 -u --media-errors
    {
      "memdev":"mem0",
      "ram_size":"256.00 MiB (268.44 MB)",
      "serial":"0",
      "host":"0000:0d:00.0",
      "firmware_version":"BWFW VERSION 00",
      "media_errors":[
        {
          "offset":"0x1000",
          "length":64,
          "source":"Injected"
        }
      ]
    }

See the *clear-media-poison* command for how to clear poison from a CXL
memory device.

This command relies on the CXL debugfs to inject poison (normally
mounted at "/sys/kernel/debug/cxl"). If the CXL debugfs is inaccesible,
the "poison_injectable" attribute will always be set to "false".

# OPTIONS

`-a; --address`  
Device physical address (DPA) to use for poison injection. Address can
be specified in hex or decimal. Required for poison injection.

`--debug`  
Enable debug output

# SEE ALSO

[cxl-list](cxl-list) [cxl-clear-media-poison](cxl-clear-media-poison)
