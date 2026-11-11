# :nodoc:
# Maps characters and keysyms to the evdev key codes and modifier keys that
# produce them with the user's keyboard layout, using libxkbcommon.
class Livetest::Keymap
  class Error < Exception
  end

  @[Link("xkbcommon")]
  lib Xkb
    struct RuleNames
      rules : UInt8*
      model : UInt8*
      layout : UInt8*
      variant : UInt8*
      options : UInt8*
    end

    fun context_new = xkb_context_new(flags : Int32) : Void*
    fun context_unref = xkb_context_unref(ctx : Void*)
    fun keymap_new_from_names = xkb_keymap_new_from_names(ctx : Void*, names : RuleNames*, flags : Int32) : Void*
    fun keymap_unref = xkb_keymap_unref(keymap : Void*)
    fun keymap_min_keycode = xkb_keymap_min_keycode(keymap : Void*) : UInt32
    fun keymap_max_keycode = xkb_keymap_max_keycode(keymap : Void*) : UInt32
    fun keymap_num_layouts = xkb_keymap_num_layouts(keymap : Void*) : UInt32
    fun keymap_num_levels_for_key = xkb_keymap_num_levels_for_key(keymap : Void*, key : UInt32, layout : UInt32) : UInt32
    fun keymap_key_get_syms_by_level = xkb_keymap_key_get_syms_by_level(keymap : Void*, key : UInt32, layout : UInt32, level : UInt32, syms : UInt32**) : Int32
    fun keymap_key_get_mods_for_level = xkb_keymap_key_get_mods_for_level(keymap : Void*, key : UInt32, layout : UInt32, level : UInt32, masks : UInt32*, size : LibC::SizeT) : LibC::SizeT
    fun state_new = xkb_state_new(keymap : Void*) : Void*
    fun state_unref = xkb_state_unref(state : Void*)
    fun state_update_key = xkb_state_update_key(state : Void*, key : UInt32, direction : Int32) : Int32
    fun state_serialize_mods = xkb_state_serialize_mods(state : Void*, components : Int32) : UInt32
    fun state_serialize_layout = xkb_state_serialize_layout(state : Void*, components : Int32) : UInt32
    fun keymap_new_from_string = xkb_keymap_new_from_string(ctx : Void*, string : UInt8*, format : Int32, flags : Int32) : Void*
    fun keysym_from_name = xkb_keysym_from_name(name : UInt8*, flags : Int32) : UInt32
    fun utf32_to_keysym = xkb_utf32_to_keysym(ucs : UInt32) : UInt32
    fun keymap_get_as_string = xkb_keymap_get_as_string(keymap : Void*, format : Int32) : UInt8*
  end

  private KEYSYM_CASE_INSENSITIVE =     1
  private STATE_MODS_DEPRESSED    =     1
  private KEY_DOWN                =     1
  private EVDEV_OFFSET            = 8_u32
  private TEXT_V1                 =     1

  # Modifier names accepted in key combinations and the keysyms of the keys
  # that hold them.
  MODIFIERS = {
    "shift" => 0xffe1_u32, # Shift_L
    "ctrl"  => 0xffe3_u32, # Control_L
    "alt"   => 0xffe9_u32, # Alt_L
    "super" => 0xffeb_u32, # Super_L
    "altgr" => 0xfe03_u32, # ISO_Level3_Shift
  }

  # How to produce a keysym: the evdev code and the modifier keys to hold.
  record Stroke, code : UInt16, modifiers : Array(UInt16)

  # keysym → {evdev code, modifier mask}, fewest modifiers first.
  @syms = {} of UInt32 => {UInt16, UInt32}
  # single modifier bit → evdev code of a key that sets it
  @mod_keys = {} of UInt32 => UInt16

  getter description : String
  # The keymap of the active layout alone (xkb text format), for compositors
  # and the offscreen worker: its key codes and modifiers match this map.
  getter text : String = ""

  # Builds the map for *layout* (comma-separated like `be,us`) and the
  # matching *variant*, *model* and *options*, at layout index *group*.
  def initialize(layout : String?, variant : String?, model : String?, options : String?, group : Int32 = 0)
    @description = "#{layout || "default"}#{variant.presence.try { |v| "(#{v})" }} group #{group}"
    ctx = Xkb.context_new(0)
    raise Error.new("xkb_context_new failed") if ctx.null?
    names = Xkb::RuleNames.new(rules: "evdev".to_unsafe, model: cstr(model), layout: cstr(layout),
      variant: cstr(variant), options: cstr(options))
    keymap = Xkb.keymap_new_from_names(ctx, pointerof(names), 0)
    if keymap.null?
      Xkb.context_unref(ctx)
      raise Error.new("cannot compile the xkb keymap for #{@description}")
    end
    begin
      group = 0 unless 0 <= group < Xkb.keymap_num_layouts(keymap)
      index(keymap, group.to_u32)
      @text = single_text(ctx, model, options, layout.try(&.split(',')[group]?), variant.try(&.split(',')[group]?))
    ensure
      Xkb.keymap_unref(keymap)
      Xkb.context_unref(ctx)
    end
  end

  private def single_text(ctx : Void*, model : String?, options : String?, layout : String?, variant : String?) : String
    names = Xkb::RuleNames.new(rules: "evdev".to_unsafe, model: cstr(model), layout: cstr(layout),
      variant: cstr(variant), options: cstr(options))
    keymap = Xkb.keymap_new_from_names(ctx, pointerof(names), 0)
    raise Error.new("cannot compile the xkb keymap for #{layout}") if keymap.null?
    begin
      raw = Xkb.keymap_get_as_string(keymap, TEXT_V1)
      raise Error.new("cannot serialize the xkb keymap") if raw.null?
      text = String.new(raw)
      LibC.free(raw.as(Void*))
      text
    ensure
      Xkb.keymap_unref(keymap)
    end
  end

  private def cstr(s : String?) : UInt8*
    s.presence.try(&.to_unsafe) || Pointer(UInt8).null
  end

  # Reads the layout KDE uses from `kxkbrc` and the active layout index from
  # *group*; falls back to the xkbcommon defaults.
  def self.kde(group : Int32 = 0) : Keymap
    path = File.join(ENV["XDG_CONFIG_HOME"]? || File.join(Path.home.to_s, ".config"), "kxkbrc")
    values = {} of String => String
    if File.exists?(path)
      section = ""
      File.each_line(path) do |line|
        line = line.strip
        if line.starts_with?('[')
          section = line
        elsif section == "[Layout]" && (eq = line.index('='))
          values[line[0, eq]] = line[eq + 1..]
        end
      end
    end
    if values["Use"]? == "false" || values["LayoutList"]?.to_s.empty?
      new(nil, nil, nil, nil, 0)
    else
      new(values["LayoutList"]?, values["VariantList"]?, values["Model"]?, values["Options"]?, group)
    end
  end

  private def index(keymap : Void*, group : UInt32) : Nil
    state = Xkb.state_new(keymap)
    begin
      each_level(keymap, group) do |key, code, sym, mask, level|
        learn_modifier(state, key, code) if level == 0 && mask == 0 && MODIFIERS.values.includes?(sym)
      end
    ensure
      Xkb.state_unref(state)
    end
    known = @mod_keys.keys.reduce(0_u32) { |acc, m| acc | m }
    each_level(keymap, group) do |_, code, sym, mask, _|
      next if 0xff80 <= sym <= 0xffbd # keypad: depends on Num Lock
      next unless mask & ~known == 0
      best = @syms[sym]?
      @syms[sym] = {code, mask} if best.nil? || better?(mask, code, best)
    end
  end

  # Yields xkb keycode, evdev code, keysym, modifier mask and level for
  # every single-keysym level of the keys with an evdev code below 256.
  private def each_level(keymap : Void*, group : UInt32, &) : Nil
    min = Xkb.keymap_min_keycode(keymap)
    max = Xkb.keymap_max_keycode(keymap)
    (min..max).each do |key|
      next if key < EVDEV_OFFSET || key - EVDEV_OFFSET > 255
      code = (key - EVDEV_OFFSET).to_u16
      Xkb.keymap_num_levels_for_key(keymap, key, group).times do |level|
        syms = Pointer(UInt32).null
        next unless Xkb.keymap_key_get_syms_by_level(keymap, key, group, level, pointerof(syms)) == 1
        sym = syms[0]
        masks = StaticArray(UInt32, 16).new(0_u32)
        count = Xkb.keymap_key_get_mods_for_level(keymap, key, group, level, masks.to_unsafe, 16)
        count.times { |m| yield key, code, sym, masks[m], level }
      end
    end
  end

  private def better?(mask : UInt32, code : UInt16, best : {UInt16, UInt32}) : Bool
    a = mask.popcount
    b = best[1].popcount
    a < b || (a == b && code < best[0])
  end

  private def learn_modifier(state : Void*, key : UInt32, code : UInt16) : Nil
    Xkb.state_update_key(state, key, KEY_DOWN)
    mask = Xkb.state_serialize_mods(state, STATE_MODS_DEPRESSED)
    Xkb.state_update_key(state, key, 0)
    return unless mask.popcount == 1
    @mod_keys[mask] = code unless @mod_keys.has_key?(mask)
  end

  # Returns the stroke that types *char*, or nil when the layout lacks it.
  def char(char : Char) : Stroke?
    sym = case char
          when '\n', '\r' then 0xff0d_u32
          when '\t'       then 0xff09_u32
          when '\e'       then 0xff1b_u32
          when '\b'       then 0xff08_u32
          else                 Xkb.utf32_to_keysym(char.ord.to_u32)
          end
    keysym(sym)
  end

  # Returns the stroke for the keysym named *name* (`Return`, `F5`, `a`).
  def named(name : String) : Stroke?
    sym = Xkb.keysym_from_name(name, 0)
    sym = Xkb.keysym_from_name(name, KEYSYM_CASE_INSENSITIVE) if sym == 0
    return nil if sym == 0
    keysym(sym)
  end

  # Returns the stroke for *sym*, or nil when no key produces it.
  def keysym(sym : UInt32) : Stroke?
    code, mask = @syms[sym]? || return nil
    mods = [] of UInt16
    32.times do |bit|
      m = 1_u32 << bit
      next if mask & m == 0
      mods << (@mod_keys[m]? || return nil)
    end
    Stroke.new(code, mods)
  end

  # Returns the evdev code of the modifier key *name* (see `MODIFIERS`).
  def modifier(name : String) : UInt16?
    sym = MODIFIERS[name.downcase]? || return nil
    @syms[sym]?.try { |(code, mask)| mask == 0 ? code : nil }
  end
end
