#MODULE_TOPDIR = ../..
MODULE_TOPDIR = /usr/local/grass83

SCRIPTDIR := .
PGM := g.cimis.daily_solar

include $(MODULE_TOPDIR)/include/Make/ShScript.make

default: script
