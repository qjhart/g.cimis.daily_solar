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
DEBUG=0

#%Module
#%  description: Runs standard Spatial CIMIS Daily Insolation Calculations
#%  keywords: CIMIS evapotranspiration
#%End
#%flag
#% key: x
#% description: fetch the latest GOES 18 data from Amazon S3 if they do not exist
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
#%option
#% key: pattern
#% type: string
#% description: Replace pattern '[01][0-9][0-2][0-9]PST-B2' for testing only
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
  GBL[linke]="${GBL[MM]}-${closest[${GBL[DD]}]}@linke"
}

# Get the earliest sunrise and latest sunset
function G_sunrise_sunset() {
  if !(g.gisenv get=sunrise store=mapset 2>/dev/null && g.gisenv get=sunset store=mapset 2>/dev/null) || ${GBL[force]}; then
  g.message -d debug=$DEBUG  message="r.iheliosat --overwrite elevation=${GBL[elevation]} linke=${GBL[linke]} sretr=sretr ssetr=ssetr year=${GBL[YYYY]} month=${GBL[MM]} day=${GBL[DD]}"
  r.iheliosat --quiet --overwrite elevation=${GBL[elevation]} linke=${GBL[linke]} sretr=sretr ssetr=ssetr year=${GBL[YYYY]} month=${GBL[MM]} day=${GBL[DD]} timezone=${GBL[tz]}
  eval $(r.info -r sretr) && GBL[sunrise]=${min%.*}
  eval $(r.info -r ssetr) && GBL[sunset]=${max%.*}
  g.gisenv set="sunrise=${GBL[sunrise]}" store=mapset
  g.gisenv set="sunset=${GBL[sunset]}" store=mapset
  ${GBL[save]} || g.remove --quiet -f type=rast name=sretr,ssetr
  else
    GBL[sunrise]=$(g.gisenv get=sunrise store=mapset)
    GBL[sunset]=$(g.gisenv get=sunset store=mapset)
  fi
  g.message -d debug=$DEBUG  message="From ${GBL[sunrise]} to ${GBL[sunset]}"
}

function get_image_interval_list() {
  local interval=${GBL[interval]}
  local sunrise=${GBL[sunrise]}
  local sunset=${GBL[sunset]}
  local from=$(( $sunrise / $interval * $interval ))
  # For GOES 18, intervals start at the 1 minute mark
  from=$(( $from + 1 ))
  local list=
  while true; do
    local h=$(printf "%02d" $(( $from / 60 )))
    local m=$(printf "%02d" $(( $from % 60 )))
    list+="$h$mPST-B2 "
    from=$(( $from + $interval ))
    if [[ $from -gt $sunset ]]; then
      break
    fi
  done
  echo ${list:0:-1}
}

# https://github.com/awslabs/open-data-docs/tree/main/docs/noaa/noaa-goes16
function fetch_B2() {
  local list=$(get_image_interval_list)
  g.message -d debug=$DEBUG message="image_interval_list=$list"
  # GET Amazon S3 bucket files
  local cache=${GBL[tmpdir]}/${GBL[YYYY]}/${GBL[MM]}/${GBL[DD]}
  [[ -d $cache ]] || mkdir -p $cache
  g.message -d debug=$DEBUG message="aws s3 list s3://${GBL[s3]}/ABI-L1b-RadC/${GBL[YYYY]}/${GBL[DOY]}/"
  aws s3 list s3://${GBL[s3]}/ABI-L1b-RadC/${GBL[YYYY]}/${GBL[DOY]}/ --recursive --no-sign-request > $cache/goes18.list
  # Get assoc array of filename from aws s3 list
  declare -A files
  for f in $(grep M6C02_G18 s3.txt | tr -s ' ' | cut -d' ' -f4); do
    local k=$(echo $f | sed -e 's/.*_s'"${y}${j}"'\(....\)[0-9][0-9][0-9]_e.*$/\1/');
    files[$k]=$f
  done

  # Verify setup
  g.region -d; r.mask -r
  for B in $list; do
    if ((! r.info -r $B >/dev/null 2>&1 ) || ${GBL[force]}) && [[ -n ${files[$B]} ]]; then
      local fn=${files[$B]}
      local cache_fn=$cache/$(basename $fn)
      if [[ ! -f $cache_fn ]]; then
        g.message -d debug=$DEBUG message="aws s3 cp s3://${GBL[s3]}/$fn $cache_fn"
        aws s3 cp s3://${GBL[s3]}/$fn $cache_fn
      fi
      # Import the file
      g.message -d debug=$DEBUG message="r.in.gdal input=NETCDF:\"$cache_fn\":Rad output=$B location=goes18"
      r.in.gdal input=NETCDF:"$cache_fn":Rad output=$B location=goes18
      # Remove cache file
      [[ ${GBL[save]} ]] || rm -f $cache_fn
      # Project to the correct location
      g.message -d debug=$DEBUG message="r.proj input=$B location=goes18 output=$B method=lanczos"
      r.proj input=$B location=goes18 output=$B method=lanczos
      # Remove the original file
      [[ ${GBL[save]} ]] || (g.mapset location=goes18 mapset=${GBL[mapset]}; g.remove --quiet -f type=rast name=$B location=goes18)
    fi
  done
}

### These functions are called at each timestep
# Calculate the integrated Clear sky radiance
function rast_Gi() {
  local h=${1:0:2}
  local m=${1:2:2}
  local Gi=${h}${m}PST-Gi
  if (! r.info -h map=$Gi >/dev/null 2>&1 ) || ${GBL[force]}; then
    local cmd="r.iheliosat  --quiet --overwrite elevation=${GBL[elevation]} linke=${GBL[linke]} total=$Gi year=${GBL[YYYY]} month=${GBL[MM]} day=${GBL[DD]} hour=${h} minute=${m} timezone=${GBL[tz]}"
    g.message -d debug=$DEBUG  message="$cmd"
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
  local t=${B}_5x5
  if ! (g.gisenv get="$t" store=mapset >/dev/null 2>&1) || ${GBL[force]}; then
    local cmd="r.neighbors --quiet --overwrite input=$B output=$t size=5 method=average"
    g.message -d debug=$DEBUG message="$cmd"
    $cmd
	  eval $(r.info -r $t)
    g.gisenv set="$t=${max%.*}" store=mapset
    ${GBL[save]} || g.remove --quiet -f type=rast name=$t
  fi
  local max=$(g.gisenv get="$t" store=mapset)
  g.message -d debug=$DEBUG message="max($t)=$max"
  echo $max
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
      #g.message -d debug=$DEBUG message="r.info $B@$m"
      if (r.info -r map="$B@$m" > /dev/null 2>&1); then
        prev+="'$B@$m',"
        #g.message -d debug=$DEBUG message="found $B@$m, prev=$prev"
      fi
    done
    prev=${prev:0:-1}
    local cmd="r.mapcalc  --quiet --overwrite expression=\"$P\"=min($prev)"
    g.message -d debug=$DEBUG message="$cmd"
    $cmd
  fi
  echo "'${P}@${GBL[YYYYMMDD]}'"
}

function rast_K() {
  local B=$1
  local hm=${B:0:4}
  local K=${hm}PST-K

  if (! r.info -r map=$K > /dev/null 2>&1 ) || ${GBL[force]}; then
    local X=$(max5x5 $B)
    local P=$(rast_P $B)
    local exp="\"$K\"=if(($X-'$B')/($X-$P)>0.2,\
	  min(($X-'$B')/($X-$P),1.09),\
	  min(0.2,(1.667)*(($X-'$B')/($X-$P))^2+(0.333)*(($X-'$B')/($X-'$B'))+0.0667))"

    g.message -d debug=$DEBUG message="r.mapcalc expression=\"$exp\""
    r.mapcalc --overwrite  --quiet expression="$exp"
  fi
  #echo "'$K@${GBL[YYYYMMDD]}'"
  echo "'$K'"
}

function rast_G() {
  local B=$1
  local hm=${B:0:4}
  local G=${hm}PST-G
  local Gi=$(rast_Gi $B)
  local K=$(rast_K $B)

  local pB=$2
  local exp

  if (! r.info -r $G >/dev/null 2>&1 ) || ${GBL[force]}; then
    if [[ -z $pB  ]]; then
      exp="\"$G\"=$Gi*$K"
    else
      local pGi=$(rast_Gi $pB)
      local pG=$(rast_G $pB)
      local pK=$(rast_K $pB)
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
    g.message -d debug=$DEBUG message="[[ $min -gt ${GBL[sunrise]} ]]"
    if [[ $min -gt ${GBL[sunrise]} ]]; then
      if [[ $min -lt ${GBL[sunset]} ]]; then
        if [[ -z $pB ]]; then
          G=$(rast_G $B)
          g.message -d debug=$DEBUG message="sunrise $G"
        else
          G=$(rast_G $B $pB)
          g.message -d debug=$DEBUG message="add $G"
        fi
        list+="$B,"
        pB=${B}
      else
        list+="$B"
        if (! r.info -r Rs >/dev/null 2>&1 ) || ${GBL[force]}; then
          Gi=$(rast_Gi $B)
          pGi=$(rast_Gi $pB)
          pK=$(rast_K $pB)
          pG=$(rast_G $pB)
          local exp="Rso=$Gi*(0.0036)"
          g.message -d debug=$DEBUG message="$exp"
          r.mapcalc  --quiet --overwrite expression="$exp"
          r.support map=Rso units="MJ/m^2 day" history="using($list)"

          exp="Rs=($pG+($pK*($Gi-$pGi)))*0.0036"
          g.message -d debug=$DEBUG message="$exp"
          r.mapcalc  --quiet --overwrite expression="$exp"
          r.support map=Rs units="MJ/m^2 day" history="using($list)"

          g.gisenv set="b2_used=$list" store=mapset
          g.message -d debug=$DEBUG message="sunset@$B"

          exp="K=Rs/Rso"
          g.message -d debug=$DEBUG message="$exp"
          r.mapcalc  --quiet --overwrite expression="$exp"
          r.support map=K description="Clear Sky Index" units="unitless" history="using($list)"

          GBL[Rs]=true
          break
        fi
      fi
    fi
  done
}

function cleanup() {
  for t in Gi_5x5 Gi G K; do
    local cmd="g.remove type=rast pattern='[0-9][0-9][0-9][0-9]PST-$t'"
    g.message -d debug=$DEBUG message="$cmd"
    #$cmd
    g.remove --quiet -f type=rast pattern="[0-9][0-9][0-9][0-9]PST-$t"
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
eval $(g.gisenv)
declare -g -A GBL
GBL[GISDBASE]=$GISDBASE
GBL[MAPSET]=$MAPSET
GBL[LOCATION_NAME]=$LOCATION_NAME
GBL[YYYYMMDD]=${GBL[MAPSET]}
GBL[YYYY]=${MAPSET:0:4}
GBL[MM]=${MAPSET:4:2}
GBL[DD]=${GBL[YYYYMMDD]:6:2}

GBL[tz]=-8
GBL[elevation]=Z@500m
GBL[interval]=20
GBL[tmpdir]=/var/tmp/cimis
GBL[DOY]=$(date --date="${GBL[YYYY]}-${GBL[MM]}-${GBL[DD]}" +%j)
GBL[s3]=noaa-goes18
GBL[pattern]='[012][0-9][0-5][0-9]PST-B2'

# Get Options
if [ $GIS_FLAG_X -eq 1 ] ; then
  GBL[fetch]=true
else
  GBL[fetch]=false
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

# test if parameter present:
if [ -n "$GIS_OPT_PATTERN" ] ; then
  GBL[pattern]="$GIS_OPT_PATTERN"
fi

if [ -n "$GIS_OPT_INTERVAL" ] ; then
  GBL[interval]="$GIS_OPT_INTERVAL"
fi

G_verify_mapset
if ! ${GBL[cleanup]}; then
  G_linke
  G_sunrise_sunset
  # Fetch files from Amazon S3
  if ${GBL[fetch]}; then
    fetch_B2
  fi
  g.message -d debug=$DEBUG message="$(declare -p GBL)"
  integrated_G
fi
# Only remove intermediate files if we are finished or clean
if ( ( ${GBL[Rs]} && ! ${GBL[save]} ) || ${GBL[cleanup]} ); then
  g.message -d debug=$DEBUG message="cleanup"
  cleanup
fi
