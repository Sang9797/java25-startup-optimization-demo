package com.example.startupdemo.compute;

import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.List;

@Service
public final class ComputeService {
    private final PrimeCalculator primeCalculator = new PrimeCalculator();
    private final ChecksumCalculator checksumCalculator = new ChecksumCalculator();
    private final WorkloadModel workloadModel = new WorkloadModel(12_000, 31);

    public ComputeResult runSampleWorkload() {
        long startedAt = System.nanoTime();
        List<Integer> primes = primeCalculator.primesUpTo(workloadModel.upperBound());
        long checksum = checksumCalculator.checksum(primes, workloadModel.salt());
        long elapsedMicros = (System.nanoTime() - startedAt) / 1_000L;
        return new ComputeResult(workloadModel.upperBound(), primes.size(), checksum, elapsedMicros);
    }

    public record ComputeResult(int inputSize, int primeCount, long checksum, long elapsedMicros) {
    }

    private static final class PrimeCalculator {
        List<Integer> primesUpTo(int upperBound) {
            List<Integer> primes = new ArrayList<>();
            for (int candidate = 2; candidate <= upperBound; candidate++) {
                if (isPrime(candidate)) {
                    primes.add(candidate);
                }
            }
            return primes;
        }

        private boolean isPrime(int value) {
            if (value < 2) {
                return false;
            }
            for (int divisor = 2; divisor * divisor <= value; divisor++) {
                if (value % divisor == 0) {
                    return false;
                }
            }
            return true;
        }
    }

    private static final class ChecksumCalculator {
        long checksum(List<Integer> values, int salt) {
            long result = 17;
            for (int value : values) {
                result = (result * 37) ^ (value + salt);
            }
            return result;
        }
    }

    private record WorkloadModel(int upperBound, int salt) {
    }
}
