local FTM = require "luaFTM.FTM"
local rView = require "luaFTM.rowView"

local MIDI = require "MIDI" -- http://www.pjb.com.au/comp/lua/MIDI.html

local kill = function (str) print(str); os.exit(false) end

local logLevels = {error=1, info=2, debug=3, debug2=4}
local l=logLevels
local defaultLogLevel = logLevels.error
local settingG -- this is very hacky

  local log = function(level, text, ...)
    if settingG.logging.logLevel >= level then
      print(text, select(1, ...))
    end
  end

FTM2MIDI = function (setting)
  local trsp = {[CHIP.FDS] = -24, [CHIP.VRC7] = -12, [CHIP.S5B] = -12}
  local APUtrsp = {23, 23, 11, 23, 12}
  
  local score = {setting.beatTicks * setting.timeMult}
  local d = 0
  local VELOCITY = {}
  if setting.nonzero then
    setmetatable(VELOCITY, {__index = function (t, k)
      if type(k) == "number" then rawset(t, k, k <= 0 and 1 or 127 * (k / 15) ^ (2 / 3)) end
      return rawget(t, k)
    end})
  else
    setmetatable(VELOCITY, {__index = function (t, k)
      if type(k) == "number" then rawset(t, k, 127 * (k / 15) ^ (2 / 3)) end
      return rawget(t, k)
    end})
  end

  local ftm = FTM:loadFTM(setting.fname)

  if setting.track < 1 or setting.track > #ftm.track then
    kill("Track " .. setting.track .. " does not exist")
  end
  local rv = rView:new(ftm, setting.track)
  local chCount = ftm:getChCount()
  local chType = ftm:getTrackChs()
  local chMap = {}
  local loop = {}

  local cMix = {}
  local cNote = {}
  local cDPCMNote
  local cInst = {}
  local cStateInst = {}
  local cTime = {}
  local cCut = {}
  local cVel = {}
  local cStateVel = {}
  local cAxy = {}
  local cArp = {}
  local cSweep = {}
  local cSpeed, cTempo = ftm.track[setting.track].speed, ftm.track[setting.track].tempo
  local cGroove = {{}, 1}
  local cEcho = {}
  if ftm.track[setting.track].groove then
    cGroove[1], cGroove[2] = ftm.groove[cSpeed + 1], 1
    cSpeed = 0
  end
  local newTempo = true

  for i = 1, chCount do
    chMap[i] = (i == 4 or i == 5) and 9 or setting.channel[i] or i > 11 and i - 2 or i > 5 and i - 3 or i - 1
    if setting.channel[i] == false then chMap[i] = false end
    cNote[i] = -1
    cStateVel[i] = 15
    cArp[i] = {[0] = true, x = 0, y = 0}
    cEcho[i] = {-1, -1, -1, -1}
    cMix[i] = 100
    if chType[i].chip == CHIP.APU and chType[i].index >= 3 then cMix[i] = 80
    elseif chType[i].chip == CHIP.S5B or chType[i].chip == CHIP.FDS then cMix[i] = 127
    end
    cMix[i] = setting.volume[i] or setting.chipVolume[chType[i].chip] or cMix[i]
    if chMap[i] then
      score[i + 1] = {
        {"track_name", 0, FTM.getChName(chType[i])},
        {"patch_change", 0, chMap[i], 0},
        --[[
        {"control_change", 0, chMap[i], 0x65, 0x00},
        {"control_change", 0, chMap[i], 0x64, 0x00},
        {"control_change", 0, chMap[i], 0x06, 12},
        {"control_change", 0, chMap[i], 0x26, 0},
        {"control_change", 0, chMap[i], 0x65, 0x7F},
        {"control_change", 0, chMap[i], 0x64, 0x7F},
        {"pitch_wheel_change", 0, chMap[i], 0},
        ]]
      }
      if not setting.swap then
        table.insert(score[i + 1], {"control_change", 0, chMap[i], 0x07, cMix[i]})
      end
    else
      score[i + 1] = {}
    end
  end
  local melCh = setting.channel[5] or 10
  if setting.channel[5] == false then melCh = false end
  local dpcmMel = melCh and {
    {"patch_change", 0, melCh, 0},
    {"control_change", 0, melCh, 0x07, setting.volume[5] or setting.chipVolume[chType[5].chip] or 80},
    {"track_name", 0, FTM.getChName(chType[5])},
  } or {}
  
  local arpDefault = {}
  for k, v in pairs(ftm.inst) do
    local s = v.seq and v.seq[2]
    if s and s.mode == 0 and s.loop and (not s.release or s.loop <= s.release) then
      arpDefault[k] = {}
      for i = s.loop, s.release or #s do
        arpDefault[k][s[i]] = true
      end
    end
  end
  
  local avgSpd = function ()
    local sp = cSpeed
    if sp == 0 then
      for _, v in ipairs(cGroove[1]) do sp = sp + v end
      sp = sp / #cGroove[1]
    end
    return sp
  end
  
  local getFTMRate = function ()
    local hz = ftm.param.rate
    return hz ~= 0 and hz or ftm.param.machine == 'PAL' and 50 or 60
  end
  
  if cTempo == 0 then
    cTempo = 2.5 * getFTMRate()
  end

  local tick = function ()
    return cTempo / avgSpd() / 2.5 / getFTMRate()
  end
  
  local getNote = function (n, ch)
    if n.note == 0x00 then return cNote[ch] end
    if n.note == 0x0D or n.note == 0x0E then return -1 end
    if n.note == 0x0F then return cEcho[ch][n.oct + 1] end
    return n.note + n.oct * 12 + (chType[ch].chip == CHIP.APU and APUtrsp[chType[ch].index] or 23)
  end
  
  local timeSignature = function (hl)
    local f = 0
    local m = setting.timeMult
    if m % 1 ~= 0 then m = 1 end
    while (hl[1] / m) % 2 ^ (f + 1) == 0 do f = f + 1 end
    local nn = hl[2] / m / 2 ^ f
    while nn % 1 ~= 0 do
      nn, f = nn * 2, f + 1
      if nn > 0xFF then
        print("Warning: out-of-bound time signature detected")
        return
      end
    end
    if f > 4 then
      print("Warning: out-of-bound time signature detected")
      return
    end
    for i = 1, chCount do
      table.insert(score[i + 1], {"time_signature", d, chMap[i], nn, 4 - f, score[1] / 4 * nn, 8})
    end
    table.insert(dpcmMel, {"time_signature", d, melCh, nn, 4 - f, score[1] / 4 * nn, 8})
  end
  
  local finishNote = function (ch)
    local d2 = 0
    local n = rv:get(ch)
    if cNote[ch] ~= -1 then
      local ins = ftm.inst[cInst[ch]]
      cNote[ch] = cNote[ch] + (trsp[chType[ch].chip] or 0)
      local Dt = ins and ins.instType == INST.APU and cDPCMNote and ins.dpcm[cDPCMNote - APUtrsp[5]]
      if chType[ch].chip == CHIP.APU then
        if chType[ch].index == 4 then
          cNote[ch] = setting.noiseMap[cInst[ch]] or cNote[ch]
        elseif chType[ch].index == 5 then
          if Dt and setting.DPCMmap[Dt.id] then cNote[ch] = setting.DPCMmap[Dt.id]
          else cNote[ch] = cNote[ch] - 1 end
        end
      elseif chType[ch].chip == CHIP.N163 and ins.instType == INST.N163 then
        cNote[ch] = cNote[ch] + math.floor(12 * math.log(16 / #ins.wave[1], 2) + .5)
      end
      local length = d + d2 - cTime[ch]
      if cCut[ch] and cCut[ch] < d + d2 then length = cCut[ch] - cTime[ch] end
      cNote[ch] = math.min(127, math.max(0, cNote[ch]))
      length = math.floor(length + .5)
      local arpTable
      if cSweep[ch] or chType[ch].chip == CHIP.APU and (chType[ch].index == 4 or chType[ch].index == 5) then
        arpTable = {[0] = true}
        cSweep[ch] = nil
      else
        local s = ins and ins.seq and ins.seq[2]
        if s and s.mode == 3 and s.loop and (not s.release or s.loop <= s.release) then -- arp scheme
          arpTable = {}
          for _, v in ipairs(s) do
            local offs, scheme = v % 64, math.floor(v / 64) % 4
            if offs > 36 then offs = offs - 64 end
            if scheme == 1 then     offs = offs + cArp[ch].x
            elseif scheme == 2 then offs = offs + cArp[ch].y
            elseif scheme == 3 then offs = offs - cArp[ch].y
            end
            arpTable[offs] = true
          end
        else
          arpTable = arpDefault[cInst[ch]] or cArp[ch]
        end
      end
      if length > 0 then
        
        local noteBeginningExtraVolume, noteAverageExtraVolume, adsrMatchedExtraVolume, overrideNoteVolume
        if setting.treatOptions then
          noteBeginningExtraVolume = -1 
          noteAverageExtraVolume = -1 
          adsrMatchedExtraVolume = -1
          overrideNoteVolume = false
          
          log(l.debug,"CH"..ch..", instr"..cInst[ch].." properties:")
          for k,v in pairs(ins) do
            log(l.debug,"", k,v)
          end
          log(l.debug2, "CH"..ch..", instr"..cInst[ch].." vol sequence:")
          for k,v in pairs(ins.seq[1] or {}) do
            log(l.debug2, "", cInst[ch],k,v)
          end

          for _,v in pairs(setting.treatOptions) do
            if (v.class=="i" and (v.selectedId == cInst[ch] or v.selectedId == -1)) then 
              if (ins.seq[1]) then -- if a volume sequence exists, otherwise ignore
                overrideNoteVolume = v.overrideNoteVolume
                local stepSize = ins.seq[1].mode == 0 and 16 or 64
                if (v.mode=="notebeginning") then 
                  noteBeginningExtraVolume = (128/stepSize)*ins.seq[1][1] -- NES to midi velocity
                elseif (v.mode=="noteaverage") then
                  local totalVol = 0
                  for _,instrVolTick in pairs(ins.seq[1]) do
                    totalVol = totalVol + instrVolTick
                  end
                  noteAverageExtraVolume = (128/stepSize)*(totalVol/#ins.seq[1]) -- NES to midi velocity
                elseif (v.mode=="adsr") then
                  local loop = ins.seq[1].loop
                  local release = ins.seq[1].release
                  log(l.debug, "CH"..ch..", instr"..cInst[ch].." loop:",loop,"release:",release)

                  local startPosition = (loop and loop+1) or 2 -- find middle section of volume sequence 
                  local endPosition = (release or #ins.seq[1]) -- and offset by 1 for next-element-search
                  log(l.debug, "CH"..ch..", instr"..cInst[ch]..": ", "startPosition="..startPosition, "endPosition="..endPosition)
                  local i = startPosition

                  local slope = 0 
                  local totalVol = ins.seq[1][i-1] -- in case of zero volume
                  while (i<endPosition+1) do
                    slope = slope+(ins.seq[1][i]-ins.seq[1][i-1])
                    totalVol = totalVol + ins.seq[1][i]
                    i=i+1
                  end
                  i=i-1 -- reset offset
                  slope=slope/(endPosition-startPosition)
                  if (slope>0) then -- attack type, use the end of the period
                    adsrMatchedExtraVolume = ins.seq[1][endPosition]
                  else -- decay/sustain type, use the beginning of the period
                    adsrMatchedExtraVolume = ins.seq[1][startPosition-1]
                  end
                  if adsrMatchedExtraVolume == 0 then -- weird volume sequence, use average instead
                    adsrMatchedExtraVolume = totalVol / (#ins.seq[1]) 
                  end
                  assert(adsrMatchedExtraVolume~=nil, "adsrMatchedExtraVolume is nil! slope="..slope.." i="..i.." #ins.seq[1]="..#ins.seq[1])
                  log(l.debug, "CH"..ch..", instr"..cInst[ch]..": slope=", slope, "adsrMatchedExtraVolume=",adsrMatchedExtraVolume)
                  adsrMatchedExtraVolume = (128/stepSize)*adsrMatchedExtraVolume -- NES to midi velocity
                end
              end
            end
          end
        end

        local volume = 
          setting.swap and cMix[ch] 
          or cVel[ch]
        if ((noteBeginningExtraVolume and noteBeginningExtraVolume>-1) or (noteAverageExtraVolume and noteAverageExtraVolume>-1) or (adsrMatchedExtraVolume and adsrMatchedExtraVolume>-1)) then
          log(l.debug2, "CH"..ch..", instr"..cInst[ch].." original volume: "..volume)
          --end
          volume = (overrideNoteVolume and 1 or (volume/128.0)) * (noteBeginningExtraVolume>-1 and noteBeginningExtraVolume
            or noteAverageExtraVolume>-1 and noteAverageExtraVolume
            or adsrMatchedExtraVolume>-1 and adsrMatchedExtraVolume
            )
          log(l.debug2, "CH"..ch..", instr"..cInst[ch].." new volume: "..volume)
        end
        if volume > 0 then
          for k in pairs(arpTable) do if k ~= "x" and k ~= "y" then
            if (ch ~= 5 or Dt and setting.DPCMmap[Dt.id] ~= false) and
               (ch ~= 4 or setting.noiseMap[cInst[ch]] ~= false) then
              if ch == 5 and setting.DPCMmelodic[Dt.id] and melCh then
                table.insert(dpcmMel, {"note", cTime[ch], length, melCh, cNote[ch] + k, volume})
              elseif chMap[ch] then
                table.insert(score[ch + 1], {"note", cTime[ch], length, chMap[ch], cNote[ch] + k, volume})
              end
            end
          end end
        end
      end
    end
    cCut[ch] = nil
  end

  if setting.timesig then
    timeSignature(ftm.param.highlight)
  end
  while true do
    local mstr = rv.frame .. ":" .. rv.row
    if loop[mstr] == setting.loops then break end
    
    for _, v in pairs(rv.lastFX) do
      if v.name == FX.HALT then
        goto outer
      elseif v.name == FX.SPEED then
        if v.param >= ftm.param.FxxSplit then
          if cTempo ~= v.param then newTempo = true end
          cTempo = v.param
        else
          if v.param == 0 then v.param = 1 end
          if cSpeed ~= v.param then newTempo = true end
          cSpeed = v.param
        end
      elseif v.name == FX.GROOVE and setting.use0CCfx then
        if cSpeed ~= 0 or cGroove[1] ~= ftm.groove[v.param + 1] then newTempo = true end
        cSpeed = 0
        cGroove[1], cGroove[2] = ftm.groove[v.param + 1], 1
      end
    end
    if newTempo then
      local ms = 10000000 * avgSpd() / cTempo / setting.timeMult
      table.insert(score[2], {"set_tempo", math.floor(d + .5), math.floor(ms + .5)})
    end
    newTempo = false
    
    for ch = 1, chCount do
      local n = rv:get(ch)
      local Gxx = nil
      for i = 4, 1, -1 do if n.fx[i] and n.fx[i].name == FX.DELAY then
        local m = cSpeed == 0 and cGroove[1][cGroove[2]] / avgSpd() or 1
        Gxx = score[1] / 4 * math.min(m, math.max(0, n.fx[i].param * tick()))
        d = d + Gxx
        break
      end end
      if n.vol ~= 0x10 then
        if cStateVel[ch] ~= n.vol and setting.swap then
          table.insert(score[ch + 1], {"control_change", math.floor(d + .5), chMap[ch], 0x07, VELOCITY[n.vol]})
        end
        cStateVel[ch] = n.vol
        if cAxy[ch] then cAxy[ch].d = d end
      end
      if n.inst ~= 0x40 then
        local old = cStateInst[ch]
        local new = n.inst + 1
        if chMap[ch] and old ~= new and setting.instMap[new] ~= false and
           ((setting.instMap[old] or 0) ~= (setting.instMap[new] or 0)) then
          if chMap[ch] ~= 9 then
            table.insert(score[ch + 1], {"patch_change", math.floor(d + .5), chMap[ch], setting.instMap[new] or 0})
          elseif ch == 5 then
            table.insert(dpcmMel, {"patch_change", math.floor(d + .5), melCh, setting.instMap[new] or 0})
          end
        end
        cStateInst[ch] = new
      end
      local tie = setting.tie[n.inst] and n.note > 0x00 and n.note < 0x0D and cNote[ch] == getNote(n, ch)
      if tie and cCut[ch] then
        if cCut[ch] >= d then cCut[ch] = nil
        else tie = false end
      end
      local noTie = false
      for i = 4, 1, -1 do if n.fx[i] then
        if n.fx[i].name == FX.ARPEGGIO then
          noTie = true
        elseif n.fx[i].param % 0x10 ~= 0 and (setting.use0CCfx and n.fx[i].name == FX.TRANSPOSE or
           n.fx[i].name == FX.SLIDE_UP or n.fx[i].name == FX.SLIDE_DOWN) then
          noTie = true
        end
      end end
      if noTie or (not tie and n.note ~= 0 and (n.note ~= 0x0D or not setting.release)) then -- ignore echo
        finishNote(ch)
        cVel[ch] = VELOCITY[cStateVel[ch]]
        cInst[ch] = cStateInst[ch]
        cNote[ch] = getNote(n, ch)
        for i = #cEcho[ch], 2, -1 do cEcho[ch][i] = cEcho[ch][i - 1] end
        if chType[ch].chip == CHIP.APU and chType[ch].index == 5 then cDPCMNote = cNote[ch] end
        cTime[ch] = d
        local used = {}
        for i = 4, 1, -1 do if n.fx[i] and not used[n.fx[i].name] then
          if n.fx[i].name == FX.SLIDE_UP then
            cNote[ch] = cNote[ch] + n.fx[i].param % 0x10
          elseif n.fx[i].name == FX.SLIDE_DOWN then
            cNote[ch] = cNote[ch] - n.fx[i].param % 0x10
          elseif n.fx[i].name == FX.TRANSPOSE and setting.use0CCfx then
            cNote[ch] = cNote[ch] + n.fx[i].param % 0x10 * (n.fx[i].param >= 0x80 and -1 or 1)
          elseif (n.fx[i].name == FX.SWEEPUP or n.fx[i].name == FX.SWEEPDOWN) and ch <= 2 then
            cSweep[ch] = true
          end
          used[n.fx[i].name] = true
        end end
        cEcho[ch][1] = cNote[ch]
        cTime[ch] = math.floor(cTime[ch] + .5)
      end
      for i = 4, 1, -1 do if n.fx[i] then
        if n.fx[i].name == FX.ARPEGGIO then
          cArp[ch] = {[0] = true, x = math.floor(n.fx[i].param / 0x10), y = n.fx[i].param % 0x10}
          cArp[ch][cArp[ch].x], cArp[ch][cArp[ch].y] = true, true
        elseif n.fx[i].name == FX.PORTA_UP or n.fx[i].name == FX.PORTA_DOWN
            or n.fx[i].name == FX.SLIDE_UP or n.fx[i].name == FX.SLIDE_DOWN
            or n.fx[i].name == FX.PORTAMENTO then
          cArp[ch] = {[0] = true, x = 0, y = 0}
        elseif setting.use0CCfx and not setting.release and n.fx[i].name == FX.NOTE_RELEASE
            or n.fx[i].name == FX.NOTE_CUT then
          if not cCut[ch] then cCut[ch] = d + score[1] / 4 * n.fx[i].param * tick() end
        elseif n.fx[i].name == FX.VOLUME_SLIDE and ch ~= 5 then
          local rate = math.floor(n.fx[i].param / 0x10) - n.fx[i].param % 0x10
          if rate == 0 then
            cAxy[ch] = nil
          else
            local clock = cAxy[ch] and cAxy[ch].clock * cAxy[ch].rate / rate or 0
            cAxy[ch] = {rate = math.abs(rate), dir = rate > 0 and 1 or -1, clock = 0}
          end
        end
      end end
      if Gxx then d = d - Gxx end
    end

    if not loop[mstr] then loop[mstr] = 0 end
    loop[mstr] = loop[mstr] + 1
    rv:step(true)
    if (rv.frame==1 and rv.row==1) then log(l.info, "Loop #"..loop[mstr].." done") end
    local dtime = score[1] / 4 * (cSpeed == 0 and cGroove[1][cGroove[2]] / avgSpd() or 1)
    for ch = 1, chCount do
      if cAxy[ch] and cStateVel[ch] + cAxy[ch].dir <= 15 and cStateVel[ch] + cAxy[ch].dir >= 0 then
        cAxy[ch].clock = cAxy[ch].clock + dtime
        local period = score[1] * 2 * tick() / cAxy[ch].rate
        while cAxy[ch].clock >= period do
          cAxy[ch].clock = cAxy[ch].clock - period
          local newv = math.min(15, math.max(0, cStateVel[ch] + cAxy[ch].dir))
          if cStateVel[ch] ~= newv and setting.swap then
            table.insert(score[ch + 1], {"control_change", math.floor(d + dtime - cAxy[ch].clock + .5), chMap[ch], 0x07, VELOCITY[newv]})
          end
          cStateVel[ch] = newv
        end
      end
    end
    d = d + dtime
    if cSpeed == 0 then
      cGroove[2] = cGroove[2] % #cGroove[1] + 1
    end
  end
  log(l.info, "Pattern data done")
  ::outer::

  d = math.floor(d + .5)
  for i = 1, chCount do
    finishNote(i)
    table.insert(score[i + 1], {"end_track", d})
  end
  table.insert(dpcmMel, {"end_track", d})
  table.insert(score, dpcmMel)
  for i = #score, 2, -1 do
    for _, v in ipairs(score[i]) do
      if v[1] == "note" then goto continue end
    end
    table.remove(score, i)
    ::continue::
  end
  score[1] = score[1] / setting.timeMult
  local fn = setting.outName or string.gsub(setting.fname, "%.ftm$", "") .. "-" .. setting.track .. ".mid"
  fn = string.gsub(setting.fname, "[^/]*$", "") .. string.match(fn, "[^/]*$")
  local midifile = assert(io.open(fn, "wb"))
  midifile:write(MIDI.score2midi(score))
  midifile:close()
  print("Successfully created " .. fn .. ".")
end

if #arg == 0 then
  print([[
Usage: lua ftm2mid.lua [filename] ([option ...])
Options:
 -0    Enable 0CC-FT effects (Lxx / Oxx / Txy) from FTMs
       Do NOT use this option for FTMs saved with 0.5.0 beta!
 -A    Treat channel volume as-is rather than as note velocity
 -Cx,y Map channel x to MIDI channel y (0 - 15)
 -Dx,y Map DPCM sample x to MIDI percussion note y (0 - 127)
 -I    Add time signatures to output
 -Kx   Set the number of MIDI ticks per quarter note to x (default 96)
 -Lx   Export the track up to x loops (default 2)
 -Mx   Set the time multiplier to x
 -mx   Divide the time multiplier by x
 -Nx,y Map instrument x on the noise channel to MIDI percussion note y
 -O x  Rename the output file to x
 -Px,y Assign instrument x to MIDI instrument y (0 - 127)
 -px   Treat DPCM sample x as melodic note
 -R    Do not treat note release as note off
 -Tx   Export track x (default 1)
 -Vx,y Set the volume of chip x to y (0 - 127)
       x: 0->2A03, 1->VRC6, 2->VRC7, 4->FDS, 8->MMC5, 16->N163, 32->5B
 -vx,y Set the volume of channel x to y (0 - 127)
 -X,.. Treat instrument, channel, and note volume as the following:
   X,ix,adsr ADSR modelling.
               Uses the middle section starting/ending volume, depending on the volume slope.
               A volume loop or a level before a release will be considered if either exists. 
               Otherwise uses starting volume if the volume sequence is 'descending' (decay-sustain/release), 
                ending volume if the volume sequence is 'ascending' (attack).
               If the resulting velocity would be zero then the average of the middle section will be taken.
   X,ix,nb   Treat beginning of instrument x volume as note velocity
   X,ix,na   Treat instrument x average volume as note velocity
]]..--[[   X,ix,pw   Feed pulse width setting into MIDI CC 12 (Effect 1)]][[
 ✓ Multiple -X are accepted.
 ✓ Adding an 'o' after an instrument option (-Xo,ix,..) will override the note velocity 
 ✓ Leaving 'x' as the instrument/channel number will make the setting apply to all of them!
    rather than mixing with channel volume (previous default)
 -Yx   Recognize instrument x as tie notes
 -Z    Force notes to use non-zero velocity and volume
 -z    Verbose, add more for increased verbosity (info, debug, debug2)]])
 --[[;-Sx;y Split instrument y from channel x to a separate track]]
else
  local int = function (str)
    local x = tonumber(str)
    if not x or x % 1 ~= 0 then kill("Unknown option parameter") end
    return x
  end
  local setting = {
    fname = arg[1],
    track = 1,
    loops = 2,
    instMap = {},
    noiseMap = {},
    DPCMmap = {},
    DPCMmelodic = {},
    tie = {},
    timeMult = 1,
    beatTicks = 96,
    volume = {},
    chipVolume = {},
    channel = {},
    logging = {
      logLevel = defaultLogLevel
    },
  }
  local func = {}
    func.A = function (t)
      setting.swap = true
    end
    func.C = function (t)
      setting.channel[int(t[1])] = t[2] and math.max(0, math.min(15, int(t[2]))) or false
    end
    func.D = function (t)
      setting.DPCMmap[int(t[1]) + 1] = t[2] and int(t[2]) or false
    end
    func.I = function (t)
      setting.timesig = true
    end
    func.K = function (t)
      setting.beatTicks = int(t[1])
      if setting.beatTicks <= 0 then setting.beatTicks = 96 end
    end
    func.L = function (t)
      setting.loops = int(t[1])
      if setting.loops <= 0 then setting.loops = 2 end
    end
    func.M = function (t)
      setting.timeMult = int(t[1])
      if setting.timeMult <= 0 then setting.timeMult = 1 end
    end
    func.m = function (t)
      local div = int(t[1])
      setting.timeMult = setting.timeMult / (div > 0 and div or 1)
    end
    func.N = function (t)
      setting.noiseMap[int(t[1]) + 1] = t[2] and int(t[2]) or false
    end
    func.O = function (t)
      setting.outName = arg[i + 1]
      if not arg[i + 1] then kill("Missing parameter for -O") end
      i = i + 1
    end
    func.P = function (t)
      setting.instMap[int(t[1]) + 1] = t[2] and int(t[2]) or false
    end
    func.p = function (t)
      setting.DPCMmelodic[int(t[1]) + 1] = true
    end
    func.R = function (t)
      setting.release = true
    end
    func.T = function (t)
      setting.track = int(t[1])
    end
    func.V = function (t)
      setting.chipVolume[int(t[1])] = int(t[2])
    end
    func.v = function (t)
      setting.volume[int(t[1])] = int(t[2])
    end
    func.X = function (t)
      setting.treatOptions = setting.treatOptions or {}
      local newClass, newSelectedId = string.gmatch(t[2], "([c|i])(%w+)")()
      local overrideNoteVolume = false
      if newClass == nil or newSelectedId == nil then error("Missing parameter for -X") end
      log(l.debug, "-X volume treat input params:", t[1], t[2], t[3])
      if newClass == "i" and t[1] == "o" then
        newOverrideNoteVolume = true
      end

      if (newSelectedId=="x") then 
        newSelectedId=-1 
      elseif (tonumber(newSelectedId)==nil) then
        error("Unrecognized option -X" .. table.concat(t,","))
      end
      
      if t[3] == "nb" then
        table.insert(setting.treatOptions, {class=newClass, selectedId=tonumber(newSelectedId), mode="notebeginning", overrideNoteVolume = newOverrideNoteVolume})
      elseif t[3] == "na" then
        table.insert(setting.treatOptions, {class=newClass, selectedId=tonumber(newSelectedId), mode="noteaverage", overrideNoteVolume = newOverrideNoteVolume})
      elseif t[3] == "adsr" then
        table.insert(setting.treatOptions, {class=newClass, selectedId=tonumber(newSelectedId), mode="adsr", overrideNoteVolume = newOverrideNoteVolume})
      else
        error("Unrecognized option -X" .. table.concat(t,","))
      end
    end
    func.Y = function (t)
      setting.tie[int(t[1])] = true
    end
    func.Z = function (t)
      setting.nonzero = true
    end
    func.z = function (t)
      setting.logging.logLevel = setting.logging.logLevel + 1
      for i=1,t[1]:len() do
        if string.sub(t[1],i,i)=="z" then
          setting.logging.logLevel = setting.logging.logLevel + 1
        end
      end
      log(l.debug, "setting.logging.logLevel="..setting.logging.logLevel)
    end
    func["0"] = function (t)
      setting.use0CCfx = true
    end
    settingG=setting -- this is very hacky
  for i = 2, #arg do 
    if string.sub(arg[i], 1, 1) == "-" then
      local option = string.sub(arg[i], 2, 2)
      local t = split(string.sub(arg[i], 3), ",")
      if func[option] then
        func[option](t)
      else
        error("Unrecognized option -" .. option)
      end
    end
  end
  FTM2MIDI(setting)
end