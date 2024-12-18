#!/usr/bin/env bash

############################################################################
#
# MODULE:       g.cimis.daily_solar
# AUTHOR(S):    Quinn Hart
# PURPOSE:      Use GOES visible satelitte data to calculate a daily solar insolation
# COPYRIGHT:    (C) 2024 by Quinn Hart
#
#               This program is free software under the GNU General Public
#               License (>=v2). Read the file COPYING that comes with GRASS
#               for details.
#
#############################################################################
# Change to 3 for working
DEBUG=3
#%Module
#%  description: Runs standard Spatial CIMIS Daily Insolation Calculations
#%  keywords: CIMIS evapotranspiration
#%End
#%flag
#% key: d
#% description: fetch files only
#% guisection: Main
#%end
#%flag
#% key: f
#% description: force commands to be run regardless if files exist
#% guisection: Main
#%end
#%flag
#% key: c
#% description: cleanup intermediate files (no processing)
#% guisection: Main
#%end
#%flag
#% key: s
#% description: save intermediate files
#% guisection: Main
#%end
#%flag
#% key: z
#% description: finalize, add a sunset raster if there is no sunset raster
#% guisection: Main
#%end
#%option
#% key: pattern
#% type: string
#% description: Replace pattern '[01][0-9][0-2][0-9]PST-B2' for testing only
#% required: no
#% guisection: Main
#%end
#%option
#% key: bucket
#% type: string
#% description: cloud provider bucket name, default gs://gcp-public-data-goes-18/ABI-L1b-RadC
#% required: no
#% guisection: Main
#%end
#%option
#% key: interval
#% type: integer
#% description: GOES 18 image interval in minutes (if fetching), default 20
#% required: no
#% guisection: Main
#%end

function G_verify_mapset() {
  if [[ ! ${GBL[YYYYMMDD]} =~ ^20[012][0-9][01][0-9][0-3][0-9]$ ]]; then
    g.message -e "Mapset ${GBL[YYYYMMDD]} not valid date format"
    exit 1
  fi
}

function G_linke() {
  local closest=(XX 01 01 01 01 07 07 \
                    07 07 07 07 15 15 15 15 \
                    15 15 15 21 21 21 \
                    21 21 21 21 28 28 28 \
                    28 28 28 28 )
  GBL[linke]="${GBL[MM]}-${closest[10#${GBL[DD]}]}@linke"
}

# Get the earliest sunrise and latest sunset
function G_sunrise_sunset() {
  if ! (g.gisenv --quiet get=SUNRISE store=mapset >/dev/null 2>&1 && g.gisenv --quiet get=SUNSET store=mapset >/dev/null 2>&1 ) || ${GBL[force]}; then
  g.message -d debug=$DEBUG message="r.iheliosat --overwrite elevation=${GBL[elevation]} linke=${GBL[linke]} sretr=sretr ssetr=ssetr year=${GBL[YYYY]} month=${GBL[MM]} day=${GBL[DD]}"
  r.iheliosat --quiet --overwrite elevation=${GBL[elevation]} linke=${GBL[linke]} sretr=sretr ssetr=ssetr year=${GBL[YYYY]} month=${GBL[MM]} day=${GBL[DD]} timezone=${GBL[tz]}
  eval "$(r.info -r sretr)" && GBL[SUNRISE]=${min%.*}
  eval "$(r.info -r ssetr)" && GBL[SUNSET]=${max%.*}
  g.gisenv set="SUNRISE=${GBL[SUNRISE]}" store=mapset
  g.gisenv set="SUNSET=${GBL[SUNSET]}" store=mapset
  ${GBL[save]} || g.remove --quiet -f type=rast name=sretr,ssetr
  else
    GBL[SUNRISE]=$(g.gisenv get=SUNRISE store=mapset)
    GBL[SUNSET]=$(g.gisenv get=SUNSET store=mapset)
  fi
  g.message -d debug=$DEBUG  message="From ${GBL[SUNRISE]} to ${GBL[SUNSET]}"
}

function get_image_interval_list() {
  local interval=${GBL[interval]}
  local SUNRISE=${GBL[SUNRISE]}
  local SUNSET=${GBL[SUNSET]}
  local from=$(( $SUNRISE / $interval * $interval ))
  # For GOES 18, intervals start at the 1 minute mark
  from=$(( $from + 1 ))
  local list=
  while true; do
    local h m
    h=$(printf "%02d" $(( $from / 60 )))
    m=$(printf "%02d" $(( $from % 60 )))
    list+="$h${m}PST-B2 "
    if [[ $from -gt $SUNSET ]]; then
      break
    fi
    from=$(( $from + $interval ))
  done
  echo ${list:0:-1}
}

function verify_or_remove_B2() {
  local B=$1
  local valid_cnt
  if (! r.info -r $B >/dev/null 2>&1); then
    g.message -w "Raster $B does not exist"
    return
  fi
  r.mapcalc --quiet --overwrite expression="validB2=not(isnull(\"$B\")) && \"state@500m\""
  valid_cnt=$(r.stats --quiet -c validB2 | grep '^1 ' | cut -d' ' -f2)
  if [[ -z $valid_cnt ]]; then
    valid_cnt=0
  fi
  g.remove --quiet -f type=rast name=validB2
  if (( ${valid_cnt} < ${GBL[mask_cnt]} )); then
    g.remove --quiet -f type=rast name="${B}"
    g.message -w "$B removed, has nulls (( ${valid_cnt} < ${GBL[mask_cnt]} ))"
    # chec for -P as well
    local P=${B:0:4}PST-P
    if ( r.info -r "$P" >/dev/null 2>&1 ); then
      g.remove --quiet -f type=rast name="$P"
      g.message -w "$P removed, has nulls"
    fi
  else
    g.message -d debug=$DEBUG message="Raster $B is complete"
  fi
}

function fetch_B2() {
  local list
  list=$(get_image_interval_list)
  g.message -d debug=$DEBUG message="image_interval_list=$list"
  # GET cloud bucket files
  local cache=${GBL[tmpdir]}/${GBL[YYYY]}/${GBL[MM]}/${GBL[DD]}
  [[ -d $cache ]] || mkdir -p $cache
  local doy
  declare -A files
  local day=0

  for doy in ${GBL[DOY]}  $(printf "%03d\n" $(( 10#${GBL[DOY]} + 1 ))); do
    local doy_list=$cache/${doy}.list

    local dir=$(date --date="${GBL[YYYY]}-01-01 + ${doy} days -1 days" +%Y/%j/)
    local fn_part=$(date --date="${GBL[YYYY]}-01-01 + ${doy} days -1 days" +%Y%j)
    if [[ ${GBL[bucket]} =~ ^s3 ]]; then
      local bk
      bk=$(dirname ${GBL[bucket]})
      g.message -v message="aws s3 ls ${GBL[s3]}/${dir} --recursive --no-sign-request"
      # Normalize list to full path
      aws s3 ls ${GBL[bucket]}/${dir} --recursive --no-sign-request |\
        grep M6C02_G18 | tr -s ' ' | cut -d' ' -f4 | sed "s!^!$bk/!" > $doy_list
    elif [[ ${GBL[bucket]} =~ ^gs ]]; then
      g.message -v message="gsutil ls -r ${GBL[bucket]}/${dir} | grep M6C02_G18"
      gsutil ls -r ${GBL[bucket]}/${dir} |\
        grep M6C02_G18  > $doy_list
    else
      g.message -e "Unknown bucket type ${GBL[bucket]}"
    fi

    # Get assoc array of filename from bucket list
    for f in $(cat $doy_list); do
      local k hh mm
      k=$(echo $f | sed -e 's/.*_s'"${fn_part}"'\(....\)[0-9][0-9][0-9]_e.*$/\1/');
      hh=$(( $day*24 + 10#${k:0:2} - 8 ))
      mm=${k:2:2}
      if [[ $hh -gt 0 && $hh -lt 24 ]]; then
        local b
        b=$(printf "%02d%02dPST-B2" $hh $mm)
#        g.message -d debug=$DEBUG message="k=$k hh=$hh mm=$mm b=$b f=$f"
        files[$b]=$f
      fi
    done
    day=$(( $day + 1 ))
  done
#  declare -p files

  # Verify setup
  g.region -d;
  r.mask -r >/dev/null 2>&1
  for B in $list; do
    if ( (! r.info -r $B >/dev/null 2>&1 ) || ${GBL[force]} ) && [[ -n ${files[$B]} ]]; then
      local fn=${files[$B]}
      local cache_fn
      cache_fn=$cache/$(basename $fn)
      if [[ ! -f $cache_fn ]]; then
        if [[ ${GBL[bucket]} =~ ^s3: ]]; then
          g.message -v message="aws s3 cp $fn $cache_fn"
          aws s3 cp $fn $cache_fn --no-sign-request
        elif [[ ${GBL[bucket]} =~ ^gs: ]]; then
          g.message -v message="gsutil cp $fn $cache_fn"
          gsutil cp $fn $cache_fn
        else
          g.message -e "Unknown bucket type ${GBL[bucket]}"
        fi
      fi
      # Import the file
      g.message -v message="$cache_fn => $B"
      g.message -d debug=$DEBUG message="r.in.gdal input=NETCDF:\"$cache_fn\":Rad output=$B"
      local tmpmap=${GBL[tmpdir]}/goes18/${GBL[MAPSET]}
      if [[ ! -d "$tmpmap" ]]; then
        g.message -v message="tmp mapset: ${tmpmap}"
        mkdir -p "${tmpmap}"
        ln -s ${tmpmap} ${GBL[GISDBASE]}/goes18/${GBL[MAPSET]}
        cp -r ${GBL[GISDBASE]}/goes18/PERMANENT/DEFAULT_WIND ${tmpmap}/WIND
      fi
      g.mapset --quiet project=goes18 mapset=${GBL[MAPSET]}
      r.in.gdal --overwrite --quiet input=NETCDF:"$cache_fn":Rad output=$B
      g.mapset --quiet project=${GBL[PROJECT]} mapset=${GBL[MAPSET]}
      # Project to the correct project
      g.message -d debug=$DEBUG message="r.proj input=$B project=goes18 output=$B method=lanczos"
      r.proj --quiet input=$B project=goes18 output=$B method=lanczos
    fi
    # Verify there are no null in raster, delete if there are
    verify_or_remove_B2 $B

    # Check to remove cache regardless of save
    if ! ${GBL[save]}; then
      if [[ -f $cache_fn ]]; then
        g.message -d debug=$DEBUG message="rm -f $cache_fn";
        rm -f $cache_fn;
      fi
      g.mapset --quiet -c project=goes18 mapset=${GBL[MAPSET]};
      if (r.info -r map=$B > /dev/null 2>&1); then
        g.message -d debug=$DEBUG message="rm $B@${GBL[MAPSET]} project=goes18"
        g.remove --quiet -f type=rast name=$B;
      fi
      g.mapset --quiet project=${GBL[PROJECT]} mapset=${GBL[MAPSET]};
    fi
  done
  # Remove the mapset if we are not saving
  if ! ${GBL[save]}; then
    rm -f "${GBL[GISDBASE]}/goes18/${GBL[MAPSET]}"
  fi
}

### These functions are called at each timestep
# Calculate the integrated Clear sky radiance
function rast_Gi() {
  local h=${1:0:2}
  local m=${1:2:2}
  local Gi=${h}${m}PST-Gi
  if (! r.info -h map=$Gi >/dev/null 2>&1 ) || ${GBL[force]}; then
    local cmd="r.iheliosat  --quiet --overwrite elevation=${GBL[elevation]} linke=${GBL[linke]} total=$Gi year=${GBL[YYYY]} month=${GBL[MM]} day=${GBL[DD]} hour=${h} minute=${m} timezone=${GBL[tz]}"
    g.message -d debug=$DEBUG message="$cmd"
    $cmd
  fi
  echo "'$Gi@${GBL[YYYYMMDD]}'"
}

# Calculate the maximum raster value.  We can not just use the max of the raster
# since we get things like sunglints that give bad data, so we take the max of a
# 5x5 region, which is meant to get the brightest possible cloud top.  Save
# this, since it is very expensive to calculate
function max5x5() {
  local B=$1
  local t=${B}_5X5
  if (r.info -r map=$B > /dev/null 2>&1); then
    if ! (g.gisenv get="$t" store=mapset >/dev/null 2>&1) || ${GBL[force]}; then
      local cmd="r.neighbors --quiet --overwrite input=$B output=$t size=5 method=average"
      g.message -d debug=$DEBUG message="$cmd"
      $cmd
	    eval "$(r.info -r $t)"
      g.gisenv set="$t=${max%.*}" store=mapset
      ${GBL[save]} || g.remove --quiet -f type=rast name=$t
    fi
    local max
    max=$(g.gisenv get="$t" store=mapset)
    g.message -d debug=$DEBUG message="max($t)=$max"
    echo $max
  fi
}

# Get the last 14 days for the matching filename.  We use this to get the
# minimum value from the last 14 days, including the current day.
function rast_P() {
  local B=$1
  local hm=${1:0:4}
  local P=${hm}PST-P
  local prev=
  if (! r.info -r map=$P > /dev/null 2>&1) || ${GBL[force]}; then
	  for i in $(seq -14 0); do
	    m=$(date --date="${GBL[YYYYMMDD]} + $i days" +%Y%m%d);
      if (r.info -r map="$B@$m" > /dev/null 2>&1); then
        prev+="'$B@$m',"
        #g.message -d debug=$DEBUG message="found $B@$m, prev=$prev"
      fi
    done
    prev=${prev:0:-1}
    local cmd=(r.mapcalc  --quiet --overwrite "expression=\"$P\"=min($prev)")
    g.message -d debug=$DEBUG message="${cmd[*]}"
    "${cmd[@]}"
  fi
  echo "'${P}@${GBL[YYYYMMDD]}'"
}

function rast_K() {
  local B=$1
  local hm=${B:0:4}
  local K=${hm}PST-K

  if (! r.info -r map="$K" > /dev/null 2>&1 ) || ${GBL[force]}; then
    local X P exp
    X=$(max5x5 "$B")
    P=$(rast_P "$B")
    exp="\"$K\"=if(($X-'$B')/($X-$P)>0.2,\
	  min(($X-'$B')/($X-$P),1.09),\
	  min(0.2,(1.667)*(($X-'$B')/($X-$P))^2+(0.333)*(($X-'$B')/($X-'$B'))+0.0667))"

    g.message -d debug=$DEBUG message="r.mapcalc expression=\"$exp\""
    r.mapcalc --overwrite  --quiet expression="$exp"
  fi
  #echo "'$K@${GBL[YYYYMMDD]}'"
  echo "'$K'"
}

function rast_G() {
  local B hm G Gi K
  B=$1
  hm=${B:0:4}
  G=${hm}PST-G
  Gi=$(rast_Gi $B)
  K=$(rast_K $B)

  local pB=$2
  local exp

  if (! r.info -r $G >/dev/null 2>&1 ) || ${GBL[force]}; then
    if [[ -z $pB  ]]; then
      exp="\"$G\"=$Gi*$K"
    else
      local pGi pG pK
      pGi=$(rast_Gi $pB)
      pG=$(rast_G $pB)
      pK=$(rast_K $pB)
      exp="\"$G\"=$pG+(($pK+$K)/2*($Gi-$pGi))"
    fi
    g.message -d debug=$DEBUG message="r.mapcalc expression=\"$exp\""
    r.mapcalc  --quiet --overwrite expression="$exp"
  fi
  #echo "'$G@${GBL[YYYYMMDD]}'"
  echo "'$G'"
}


function integrated_G() {
  local pB=
  local list=
  g.message -d debug=$DEBUG message="g.list type=rast pattern=\"${GBL[pattern]}\""
  for B in $(g.list -e type=rast pattern="${GBL[pattern]}" | sort); do
    g.message -d debug=$DEBUG message="$B"
    local h=${B:0:2}
    local m=${B:2:2}
    local min=$((10#$h*60+10#$m))
    local G
    if [[ $min -gt ${GBL[SUNRISE]} ]]; then
      if [[ $min -lt ${GBL[SUNSET]} ]]; then
        if [[ -z $pB ]]; then
          G=$(rast_G $B)
          g.message -v message="[[ $min -gt ${GBL[SUNRISE]} ]] sunrise $G"
        else
          G=$(rast_G $B $pB)
          g.message -v message="[[ $min -gt ${GBL[SUNRISE]} ]] && [[ $min -lt ${GBL[SUNSET]} ]] add $G"
        fi
        list+="$B,"
        pB=${B}
      else
        list+="$B"
        local Gi pGi pK pG
        Gi=$(rast_Gi $B)
        pGi=$(rast_Gi $pB)
        pK=$(rast_K $pB)
        pG=$(rast_G $pB)
        local exp
        exp="Rso=$Gi*(0.0036)"
        g.message -d debug=$DEBUG message="$exp"
        r.mapcalc  --quiet --overwrite expression="$exp"
        r.support map=Rso units="MJ/m^2 day" history="using($list)"

        exp="Rs=($pG+($pK*($Gi-$pGi)))*0.0036"
        g.message -d debug=$DEBUG message="$exp"
        r.mapcalc  --quiet --overwrite expression="$exp"
        r.support map=Rs units="MJ/m^2 day" history="using($list)"

        g.gisenv set="B2_USED=$list" store=mapset
        g.message -d debug=$DEBUG message="sunset@$B"

        exp="K=Rs/Rso"
        g.message -d debug=$DEBUG message="$exp"
        r.mapcalc  --quiet --overwrite expression="$exp"
        r.support map=K description="Clear Sky Index" units="unitless" history="using($list)"

        g.message -v message="[[ $min -gt ${GBL[SUNSET]} ]] sunset ${Gi}, Rs, K"

        GBL[Rs]=true
        break
      fi
    fi
  done
}

function cleanup() {
  local cmd
  for t in P Gi G K B2_5X5; do
    cmd="g.remove type=rast pattern='[0-9][0-9][0-9][0-9]PST-$t'"
    g.message -v message="$cmd"
    #$cmd
    g.remove --quiet -f type=rast pattern="[0-9][0-9][0-9][0-9]PST-$t" 2>/dev/null
  done
}


## MAIN Program
if  [ -z "$GISBASE" ] ; then
    echo "You must be in GRASS GIS to run this program."
    exit 1
fi

# save command line
if [ "$1" != "@ARGS_PARSED@" ] ; then
    exec g.parser "$0" "$@"
fi


# CIMIS uses YYYYMMDD for all standard mapsets
# Global variables
eval "$(g.gisenv)"
declare -g -A GBL
GBL[GISDBASE]=$GISDBASE
GBL[MAPSET]=$MAPSET
GBL[PROJECT]=$LOCATION_NAME
GBL[YYYYMMDD]=${GBL[MAPSET]}
GBL[YYYY]=${MAPSET:0:4}
GBL[MM]=${MAPSET:4:2}
GBL[DD]=${GBL[YYYYMMDD]:6:2}

GBL[tz]=-8
GBL[elevation]=Z@500m
GBL[interval]=20
GBL[tmpdir]=/var/tmp/cimis
GBL[DOY]=$(date --date="${GBL[YYYY]}-${GBL[MM]}-${GBL[DD]}" +%j)
GBL[s3_bucket]='s3://noaa-goes18/ABI-L1b-RadC'
GBL[gs_bucket]='gs://gcp-public-data-goes-18/ABI-L1b-RadC'
GBL[pattern]='[012][0-9][0-5][0-9]PST-B2'

GBL[mask]="state@500m"
GBL[mask_cnt]=1642286

GBL[finalize]=false  # Add a sunset raster if there is no sunset raster

# Verify the mask
function verify_mask() {
  local mask_cnt
  mask_cnt=$(r.stats --quiet -n -c state@500m  | cut -d' ' -f2)
  if (( $mask_cnt != ${GBL[mask_cnt]} )); then
    g.message -e "Mask count (${GBL[mask_cnt]})=$mask_cnt, expected ${GBL[mask_cnt]}.  You may have another mask in place."
    exit 1
  fi
}



# Get Options
if [ $GIS_FLAG_D -eq 1 ] ; then
  GBL[fetch_only]=true
else
  GBL[fetch_only]=false
fi

if [ $GIS_FLAG_F -eq 1 ] ; then
  GBL[force]=true
else
  GBL[force]=false
fi

if [ $GIS_FLAG_S -eq 1 ] ; then
  GBL[save]=true
else
  GBL[save]=false
fi

if [ $GIS_FLAG_C -eq 1 ] ; then
  GBL[cleanup]=true
else
  GBL[cleanup]=false
fi

if [ $GIS_FLAG_Z -eq 1 ] ; then
  GBL[finalize]=true
fi

# test if parameter present:
if [ -n "$GIS_OPT_PATTERN" ] ; then
  GBL[pattern]="$GIS_OPT_PATTERN"
fi

if [ -n "$GIS_OPT_BUCKET" ] ; then
  if [[ $GIS_OPT_BUCKET =~ ^gs:?$ ]]; then
    GBL[bucket]=${GBL[gs_bucket]}
  elif [[ $GIS_OPT_BUCKET =~ ^s3:?$ ]]; then
    GBL[bucket]=${GBL[s3_bucket]}
  else
    GBL[bucket]=$GIS_OPT_BUCKET
  fi;
  else
    GBL[bucket]=${GBL[gs_bucket]}
fi

if [ -n "$GIS_OPT_INTERVAL" ] ; then
  GBL[interval]="$GIS_OPT_INTERVAL"
fi

verify_mask
G_verify_mapset


if ! ${GBL[cleanup]}; then
  G_linke
  G_sunrise_sunset
  g.message -d debug=$DEBUG message="$(declare -p GBL)"
  # Fetch files
  if [[ -n ${GBL[bucket]} ]] ; then
    fetch_B2
    if ${GBL[fetch_only]} ;  then
      g.message -d debug=$DEBUG message="fetch only, exiting"
      exit 0
    fi
  fi
  # Make sure we have an file past sunset / Hopefully we can avoid this
  if ${GBL[finalize]}; then
    g.message -v message="finalize : '2301PST-B2=0'"
    r.mapcalc --overwrite expression='"2301PST-B2"=0'
  fi
  integrated_G
fi
# Only remove intermediate files if we are finished or clean
if ( ( ${GBL[Rs]} && ! ${GBL[save]} ) || ${GBL[cleanup]} ); then
  g.message -d debug=$DEBUG message="cleanup"
  cleanup
fi
