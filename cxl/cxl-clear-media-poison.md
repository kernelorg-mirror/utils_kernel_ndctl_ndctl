---
layout: page
---

# NAME

cxl-clear-media-poison - Clear poison from CXL memory

# SYNOPSIS

>     cxl clear-media-poison <memdev> [<options>]

Clear poison from a CXL memory device’s memory. CXL memdevs can be
specified by device name (e.g. "mem0"), device id ("X" in "memX"), or
host device name ("0000:35:00.0").

To see if a device has poison that can be cleared use the *cxl-list*
command with the *-L*/*--media-errors* option. An example of a device
that has had poison injected at device physical address (a.k.a.
"offset") 0x1000:

    # cxl list -m mem0 -L -u
    {
      "memdev":"mem0",
      "ram_size":"1024.00 MiB (1073.74 MB)",
      "ram_qos_class":42,
      "serial":"0x0",
      "numa_node:1,
      "host":"0000:35:00.0",
      "media_errors":[
        {
          "offset":"0x1000",
          "length":64,
          "source":"Injected"
        }
      ]
    }

A device physical address is required to clear poison from a CXL memdev.
The *-a*/*--address* option is used to specify the address to clear
poison at. The address can be given in either decimal or hexadecimal. An
example using the example device above:

    # cxl clear-media-poison mem0 -a 0x1000
    poison cleared at mem0:0x1000

    # cxl list -m mem0 -L -u
    {
      "memdev":"mem0",
      "ram_size":"1024.00 MiB (1073.74 MB)",
      "ram_qos_class":42,
      "serial":"0x0",
      "numa_node:1,
      "host":"0000:35:00.0",
      "media_errors":[
      ]
    }

See the *inject-media-poison* command for how to inject poison into a
CXL memory device.

This command depends on the CXL debug filesystem (normally mounted at
"/sys/kernel/debug/cxl") to clear device poison.

# OPTIONS

`-a; --address`  
Device physical address (DPA) to clear poison at. Address can be
specified in hex or decimal.

`--debug`  
Enable debug output

# SEE ALSO

[cxl-list](cxl-list) [cxl-clear-media-poison](cxl-clear-media-poison)
