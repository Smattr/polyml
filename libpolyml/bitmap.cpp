/*
    Title:  Bitmap.  Generally used by the garbage collector to indicate allocated words

    Copyright (c) 2006, 2012  David C.J. Matthews
       Based on original code in garbage_collect.c.

    This library is free software; you can redistribute it and/or
    modify it under the terms of the GNU Lesser General Public
    License as published by the Free Software Foundation; either
    version 2.1 of the License, or (at your option) any later version.
    
    This library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    Lesser General Public License for more details.
    
    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

*/

/*
   Bitmaps are used particularly in the garbage collector to indicate allocated
   words.  The efficiency of this code is crucial for the speed of the garbage
   collector.
*/

#ifdef HAVE_CONFIG_H
#include "config.h"
#elif defined(_WIN32)
#include "winconfig.h"
#else
#error "No configuration file"
#endif

#ifdef HAVE_ASSERT_H
#include <assert.h>
#define ASSERT(h) assert(h)
#else
#define ASSERT(h)
#endif

#ifdef HAVE_STDLIB_H
#include <stdlib.h>
#endif

#ifdef HAVE_MALLOC_H
#include <malloc.h>
#endif

#ifdef HAVE_STRING_H
#include <string.h>
#endif

#include "bitmap.h"
#include "globals.h"
#include <algorithm>
#include <vector>

bool Bitmap::Create(POLYUNSIGNED bits)
{
    if (bits > m_bits.max_size()) {
        // length_error would be triggered
        return false;
    }
    m_bits.resize(bits, false);
    return true;
}

void Bitmap::Destroy()
{
    // nothing required
}

Bitmap::~Bitmap()
{
    Destroy();
}

static void fill_with(std::vector<bool> &vec, POLYUNSIGNED bitno, POLYUNSIGNED length, bool value)
{
    ASSERT (0 < length); // Strictly positive

    // Write is in bounds
    ASSERT (bitno < vec.size());
    ASSERT (bitno + length - 1 < vec.size());

    std::fill_n(vec.begin() + bitno, length, value);
}

// Set a range of bits in a bitmap.
void Bitmap::SetBits(POLYUNSIGNED bitno, POLYUNSIGNED length)
{
    fill_with(m_bits, bitno, length, true);
}

// Clear a range of bits.
void Bitmap::ClearBits(POLYUNSIGNED bitno, POLYUNSIGNED length)
{
    fill_with(m_bits, bitno, length, false);
}

static POLYUNSIGNED count_consecutive(const std::vector<bool> &vec, POLYUNSIGNED bitno, POLYUNSIGNED n, bool value)
{
    POLYUNSIGNED bit_count = 0;
    ASSERT (0 < n); // Strictly positive

    // In bounds
    ASSERT (bitno < vec.size());

    for (std::vector<bool>::const_iterator it = vec.begin() + bitno; it != vec.end(); it++, bit_count++) {
        if (*it != value || bit_count == n) {
            break;
        }
    }

    return bit_count;
}

// How many zero bits (maximum n) are there in the bitmap, starting at location start? */
POLYUNSIGNED Bitmap::CountZeroBits(POLYUNSIGNED bitno, POLYUNSIGNED n) const
{
    return count_consecutive(m_bits, bitno, n, false);
}


// Search the bitmap from the high end down looking for n contiguous zeros
// Returns the value of "bitno" on failure. .
POLYUNSIGNED Bitmap::FindFree
(
  POLYUNSIGNED   limit,  /* The highest numbered bit that's too small to use */
  POLYUNSIGNED   start,  /* The lowest numbered bit that's too large to use */
  POLYUNSIGNED   n       /* The number of consecutive zero bits required */
) const
{
    if (limit + n >= start)
        return start; // Failure

    POLYUNSIGNED candidate = start - n;
    ASSERT (start > limit);
    
    while (1)
    {
        POLYUNSIGNED bits_free = CountZeroBits(candidate, n);
        
        if (n <= bits_free)
            return candidate;

        if (candidate < n - bits_free + limit)
            return start; // Failure
        
        candidate -= (n - bits_free);
    }
}

// Count the number of set bits in the bitmap.
POLYUNSIGNED Bitmap::CountSetBits(POLYUNSIGNED size) const
{
    POLYUNSIGNED count = 0;
    for (std::vector<bool>::const_iterator it = m_bits.begin(); it != m_bits.end(); it++) {
        if (*it)
            count++;
    }
    return count;
}

