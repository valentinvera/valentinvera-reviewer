#!/bin/sh
# Parse one DNS client line. The only accepted shape is
# `rcode=<0-15> answers=<count> a=<ipv4-or-empty>`.
# `NOANSWER` contains the letters ANSWER and is not a reply.
parse_dns_reply() {
  printf '%s\n' "$1" | awk '
    NF == 0 { exit 1 }
    {
      rcode = ""
      answers = ""
      addr = ""
      saw_rcode = 0
      saw_answers = 0
      saw_addr = 0
      for (i = 1; i <= NF; i++) {
        n = split($i, p, "=")
        if (n != 2) exit 1
        if (p[1] == "rcode" && !saw_rcode) { rcode = p[2]; saw_rcode = 1 }
        else if (p[1] == "answers" && !saw_answers) { answers = p[2]; saw_answers = 1 }
        else if (p[1] == "a" && !saw_addr) { addr = p[2]; saw_addr = 1 }
        else exit 1
      }
      if (!saw_rcode || !saw_answers || !saw_addr) exit 1
      if (rcode !~ /^[0-9]+$/ || rcode+0 > 15) exit 1
      if (answers !~ /^[0-9]+$/) exit 1
      if (answers+0 == 0 && addr != "") exit 1
      if (answers+0 > 0) {
        parts = split(addr, octets, ".")
        if (parts != 4) exit 1
        for (j = 1; j <= 4; j++) {
          if (octets[j] !~ /^[0-9]+$/ || octets[j]+0 > 255) exit 1
        }
      }
      print rcode+0
      print answers+0
      print addr
    }
  '
}

dns_query_count() {
  file=$1
  name=$2
  if [ ! -f "$file" ]; then
    printf '0\n'
    return 0
  fi
  awk -v name="$name" 'BEGIN { n = 0 } $0 == name { n++ } END { print n+0 }' "$file"
}
