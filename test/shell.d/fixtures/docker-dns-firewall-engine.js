// Models the IPv4 user rules ufw 0.36.2 installs, enough to decide whether a
// packet is accepted. format_rule() emits `-i` only when the rule names an
// interface (ufw/common.py), and iptables treats a trailing '+' as a name
// prefix. User rules are first-match. Incoming packets that match nothing
// follow the installer's default deny.
//
// Invoked as the `ufw` command:
//   node docker-dns-firewall-engine.js <state.json> <ufw argv...>
// Other modes:
//   node docker-dns-firewall-engine.js --seed-installed <state.json>
//   node docker-dns-firewall-engine.js --check <state.json> <what>

const fs = require('fs')

const PACKETS = [
  {
    name: 'a host on the Wi-Fi LAN querying the Docker bridge address',
    src: '192.168.1.50',
    dst: '172.17.0.1',
    dport: 53,
    proto: 'udp',
    iface: 'wlan0',
    allow: false,
  },
  {
    name: 'a Wi-Fi host spoofing a container address under loose reverse-path filtering',
    src: '172.17.0.2',
    dst: '172.17.0.1',
    dport: 53,
    proto: 'udp',
    iface: 'wlan0',
    allow: false,
  },
  {
    name: 'a host on ethernet using an address in 172.16.0.0/12',
    src: '172.18.0.5',
    dst: '172.17.0.1',
    dport: 53,
    proto: 'udp',
    iface: 'eth0',
    allow: false,
  },
  {
    name: 'TCP DNS from the Wi-Fi LAN to the Docker bridge address',
    src: '192.168.1.50',
    dst: '172.17.0.1',
    dport: 53,
    proto: 'tcp',
    iface: 'wlan0',
    allow: false,
  },
  {
    name: 'DNS to the laptop LAN address rather than the bridge address',
    src: '192.168.1.50',
    dst: '192.168.1.10',
    dport: 53,
    proto: 'udp',
    iface: 'wlan0',
    allow: false,
  },
  {
    name: 'a container on docker0 querying the host resolver',
    src: '172.17.0.2',
    dst: '172.17.0.1',
    dport: 53,
    proto: 'udp',
    iface: 'docker0',
    allow: true,
  },
  {
    name: 'a container on a user-defined bridge querying the host resolver',
    src: '172.18.0.2',
    dst: '172.17.0.1',
    dport: 53,
    proto: 'udp',
    iface: 'br-9f3a1c2d4e5f',
    allow: true,
  },
]

// Rules a machine already has after install/config/firewall.sh from the
// vulnerable installer. ufw allow only appends, so correcting the script does
// not remove these.
const INSTALLED_RULES = [
  rule({
    action: 'allow',
    direction: 'in',
    proto: 'udp',
    dport: '53317',
    comment: '',
  }),
  rule({
    action: 'allow',
    direction: 'in',
    proto: 'tcp',
    dport: '53317',
    comment: '',
  }),
  rule({
    action: 'allow',
    direction: 'in',
    proto: 'udp',
    src: '172.16.0.0/12',
    dst: '172.17.0.1',
    dport: '53',
    comment: 'allow-docker-dns',
  }),
  rule({
    action: 'allow',
    direction: 'in',
    proto: 'udp',
    src: '192.168.0.0/16',
    dst: '172.17.0.1',
    dport: '53',
    comment: 'allow-docker-dns',
  }),
]

function rule(partial) {
  return {
    action: 'allow',
    direction: 'in',
    iface: '',
    proto: 'any',
    src: 'any',
    dst: 'any',
    sport: 'any',
    dport: 'any',
    comment: '',
    ...partial,
  }
}

function emptyState() {
  return { rules: [] }
}

function loadState(path) {
  if (!fs.existsSync(path)) return emptyState()
  return JSON.parse(fs.readFileSync(path, 'utf8'))
}

function saveState(path, state) {
  fs.writeFileSync(path, JSON.stringify(state))
}

function ipToInt(ip) {
  if (!/^\d+\.\d+\.\d+\.\d+$/.test(ip)) return null
  return ip.split('.').reduce((acc, octet) => ((acc << 8) + Number(octet)) >>> 0, 0)
}

function inCidr(ip, cidr) {
  if (!cidr || cidr === 'any' || cidr === '0.0.0.0/0' || cidr === 'Anywhere') return true
  const [base, bitsText] = cidr.split('/')
  const bits = bitsText === undefined ? 32 : Number(bitsText)
  if (!Number.isInteger(bits) || bits < 0 || bits > 32) return false
  const ipInt = ipToInt(ip)
  const baseInt = ipToInt(base)
  if (ipInt === null || baseInt === null) return false
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0
  return (ipInt & mask) === (baseInt & mask)
}

function ifaceMatches(ruleIface, packetIface) {
  if (!ruleIface) return true
  if (ruleIface.endsWith('+')) return packetIface.startsWith(ruleIface.slice(0, -1))
  return ruleIface === packetIface
}

function sameRule(left, right) {
  return (
    left.action === right.action &&
    left.direction === right.direction &&
    left.iface === right.iface &&
    left.proto === right.proto &&
    left.src === right.src &&
    left.dst === right.dst &&
    left.sport === right.sport &&
    left.dport === right.dport
  )
}

function parseSpec(action, argv) {
  const parsed = rule({ action })
  let side = 'dst'
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i]
    if (token === 'in' || token === 'out') {
      parsed.direction = token
      continue
    }
    if (token === 'on') {
      parsed.iface = argv[++i] || ''
      continue
    }
    if (token === 'proto') {
      parsed.proto = argv[++i] || 'any'
      continue
    }
    if (token === 'from') {
      side = 'src'
      const addr = argv[++i] || 'any'
      parsed.src = addr === 'any' ? 'any' : addr
      continue
    }
    if (token === 'to') {
      side = 'dst'
      const addr = argv[++i] || 'any'
      parsed.dst = addr === 'any' ? 'any' : addr
      continue
    }
    if (token === 'port') {
      const port = argv[++i] || 'any'
      if (side === 'src') parsed.sport = port
      else parsed.dport = port
      continue
    }
    if (token === 'comment') {
      parsed.comment = argv.slice(i + 1).join(' ')
      break
    }
    const short = token.match(/^(\d+)\/(tcp|udp)$/)
    if (short && i === 0 && argv.length === 1) {
      parsed.dport = short[1]
      parsed.proto = short[2]
      continue
    }
    throw new Error(`unrecognized ufw rule token: ${token}`)
  }
  return parsed
}

function stripForce(argv) {
  return argv.filter((token) => token !== '--force' && token !== '-f')
}

function applyCommand(state, argv) {
  const args = stripForce(argv)
  const command = args[0]
  if (!command || command === 'default' || command === 'enable' || command === 'disable' || command === 'reload' || command === 'logging' || command === 'app' || command === 'show') {
    return
  }
  if (command === 'reset') {
    state.rules = []
    return
  }
  if (command === 'status') return
  if (command === 'insert') {
    const at = Number(args[1])
    const spec = parseSpec(args[2], args.slice(3))
    const index = Number.isInteger(at) && at > 0 ? at - 1 : state.rules.length
    state.rules.splice(index, 0, spec)
    return
  }
  if (command === 'delete') {
    if (/^\d+$/.test(args[1] || '')) {
      const index = Number(args[1]) - 1
      if (index >= 0 && index < state.rules.length) state.rules.splice(index, 1)
      return
    }
    const spec = parseSpec(args[1], args.slice(2))
    const index = state.rules.findIndex((existing) => sameRule(existing, spec))
    if (index >= 0) state.rules.splice(index, 1)
    return
  }
  if (command === 'allow' || command === 'deny' || command === 'reject' || command === 'limit') {
    state.rules.push(parseSpec(command, args.slice(1)))
    return
  }
  throw new Error(`unrecognized ufw command: ${command}`)
}

function endpoint(addr, port, proto) {
  const anywhere = !addr || addr === 'any' || addr === '0.0.0.0/0'
  let text = anywhere ? '' : addr
  if (port && port !== 'any') {
    const portText = proto && proto !== 'any' ? `${port}/${proto}` : String(port)
    text = text ? `${text} ${portText}` : portText
  }
  return text || 'Anywhere'
}

function statusText(state, numbered) {
  const lines = ['Status: active', '']
  if (state.rules.length === 0) {
    lines.push('Status: active')
    return lines.join('\n')
  }
  lines.push('     To                         Action      From')
  lines.push('     --                         ------      ----')
  state.rules.forEach((existing, index) => {
    const to = endpoint(existing.dst, existing.dport, existing.proto) + (existing.iface ? ` on ${existing.iface}` : '')
    const from = endpoint(existing.src, existing.sport, existing.sport !== 'any' ? existing.proto : 'any')
    const action = `${existing.action.toUpperCase()} IN`
    const comment = existing.comment ? ` # ${existing.comment}` : ''
    if (numbered) {
      const number = String(index + 1).padStart(2, ' ')
      lines.push(`[${number}] ${to.padEnd(26)} ${action.padEnd(12)}${from}${comment}`)
    } else {
      lines.push(`${to.padEnd(26)} ${action.padEnd(12)}${from}${comment}`)
    }
  })
  return lines.join('\n')
}

function packetAllowed(state, packet) {
  for (const existing of state.rules) {
    if (existing.direction === 'out') continue
    if (existing.proto !== 'any' && existing.proto !== packet.proto) continue
    if (!ifaceMatches(existing.iface, packet.iface)) continue
    if (!inCidr(packet.src, existing.src)) continue
    if (!inCidr(packet.dst, existing.dst)) continue
    if (existing.dport !== 'any' && Number(existing.dport) !== packet.dport) continue
    if (existing.sport !== 'any') continue
    if (existing.action === 'deny' || existing.action === 'reject') return false
    return true
  }
  return false
}

function check(state, what) {
  for (const packet of PACKETS) {
    const allowed = packetAllowed(state, packet)
    if (allowed !== packet.allow) {
      const decision = allowed ? 'allowed' : 'denied'
      const expected = packet.allow ? 'allowed' : 'denied'
      console.error(
        `${what}: ${packet.name} was ${decision}; expected it to be ${expected}.\n` +
          `packet: ${packet.proto} ${packet.src} -> ${packet.dst}:${packet.dport} in on ${packet.iface}\n` +
          `rules:\n${JSON.stringify(state.rules, null, 2)}`
      )
      process.exit(1)
    }
  }
}

function main() {
  const argv = process.argv.slice(2)
  if (argv[0] === '--seed-installed') {
    saveState(argv[1], { rules: INSTALLED_RULES })
    return
  }
  if (argv[0] === '--check') {
    check(loadState(argv[1]), argv[2] || 'firewall')
    return
  }
  const statePath = argv[0]
  const ufwArgs = argv.slice(1)
  const state = loadState(statePath)
  applyCommand(state, ufwArgs)
  saveState(statePath, state)
  if (ufwArgs[0] === 'status' || (ufwArgs[0] === '--force' && ufwArgs[1] === 'status')) {
    const numbered = ufwArgs.includes('numbered')
    process.stdout.write(`${statusText(state, numbered)}\n`)
  }
}

main()
