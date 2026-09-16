#!/usr/bin/env python

import sys
import os
import numpy as np
import argparse
import netCDF4 as nc
import shutil
import subprocess
import datetime

def combine(file1, file2, mask_filename, output_filename):

    shutil.copy2(file1, output_filename)  # start with a copy of file1 to retain its metadata and other variables

    with nc.Dataset(file1, 'r') as f1, \
         nc.Dataset(file2, 'r') as f2, \
         nc.Dataset(mask_filename, 'r') as mask, \
         nc.Dataset(output_filename, 'a') as f_out:

        # Sanity checks
        num_lons = f1.dimensions['nx'].size
        num_lats = f1.dimensions['ny'].size

        if f1['depth'].shape != f2['depth'].shape or f1['depth'].shape != mask['B_mask'].shape:
            os.remove(output_filename)  # ensure remaining workflow will fail
            raise IndexError(f'dimensions of {file1}, {file2} and {mask_filename} are not identical')

        # Combine the files, taking file2 where mask > 0 and file1 elsewhere
        f_out['depth'][:] = np.where(mask['B_mask'][:] > 0,
                                     f2.variables['depth'][:],
                                     f1.variables['depth'][:])
        f_out.setncattr('history', f"{f_out.getncattr('history')}\n{datetime.datetime.now()}: combine_by_mask.py {file1} {file2} {mask_filename} {output_filename}")

def main():

    parser = argparse.ArgumentParser()
    parser.add_argument('file1', help='First .nc file containing variable "depth".')
    parser.add_argument('file2', help='Second .nc file containing variable "depth".')
    parser.add_argument('mask', help='Mask .nc file containing variable "B_mask".')
    parser.add_argument('output', help='Output filename, containing variable "depth" taken from file2 where mask > 0 and file1 elsewhere.')

    args = parser.parse_args()

    return combine(args.file1, args.file2, args.mask, args.output)

if __name__ == '__main__':
    sys.exit(main())
