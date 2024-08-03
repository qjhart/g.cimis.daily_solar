## DESCRIPTION ##

g.cimis.daily_solar computes the standard Spatial CIMIS daily solar
  insolation.  The model combines the clear sky solar radiation model,
  r.iheliosat, with a cloud cover model to estimate radiation.

The model reads a set of raster maps representing GOES visible Band 2 data.
  The raster names are expected to be in the format of HHMMPST-B2, where HHMM is
  the time of the image, PST is the time zone, and B2 is the band number.

For each image (sorted by time), r.iheliosat is called to compute the
  clear sky radiation.  The clear sky radiation is then multiplied by the
  cloud cover map to estimate the radiation.  The cloud cover map is calculated
  from the GOES visible Band 2 data using the method of Hart et al. (2009).

At every time step, the model will also compute a number of intermediate maps
  that can be used to verify the results.  For every image HHMMPST-B2; the model
  creates:

    - HHMMPST-B2_Gi: Integrated (to that time) clear sky insolation
    - HHMMPST-B2_P: Today's estimated alebedo (min value from last 14 days)
    - HHMMPST-B2_K: Clear sky factor (0-1)
    - HHMMPST-B2_G: Time integrated clouded insolation

The model expects that at least one image arrives after sunset. At that point,
  the model will compute the total daily solar insolation, G.

## NOTES ##

The model can be run multiple times in a day.  The model will only compute
  parameters that have not been computed yet.  The model will also only compute
  the total daily solar insolation after sunset.

The total daily insolation, G, is used to compute the daily reference
  evapotranspiration (ET0) using the FAO Penman-Monteith method.

## SEE ALSO ##

r.iheliosat

## REFERENCES ##

Hart, Q., Brugnach, M., Temesgen, B., Rueda, C., Ustin, S., Frame, K. (2009)
  Daily reference evapotranspiration for California using satellite imagery and
  weather station measurement interpolation.  Civil Engineering and
  Environmental Systems, 26 (1), 19–33. https://doi.org/10.1080/10286600802003500

## AUTHORS ##

Quinn Hart, University of California, Davis © 2004-2024 Quinn Hart.
This program is free software under the MIT License
qjhart@ucdavis.edu
